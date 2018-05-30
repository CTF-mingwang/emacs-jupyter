;;; jupyter-messages.el --- Jupyter messages -*- lexical-binding: t -*-

;; Copyright (C) 2018 Nathaniel Nicandro

;; Author: Nathaniel Nicandro <nathanielnicandro@gmail.com>
;; Created: 08 Jan 2018
;; Version: 0.0.1
;; X-URL: https://github.com/nathan/jupyter-messages

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;;

;;; Code:

(require 'jupyter-base)
(require 'jupyter-channels)

(defgroup jupyter-messages nil
  "Jupyter messages"
  :group 'jupyter)

(defconst jupyter-message-delimiter "<IDS|MSG>"
  "The message delimiter required in the jupyter messaging protocol.")

(defconst jupyter--false :json-false
  "The symbol used to disambiguate nil from boolean false.")

(defconst jupyter--empty-dict (make-hash-table :size 1)
  "An empty hash table to disambiguate nil during encoding.
Message parts that are nil, but should be encoded into an empty
dictionary are set to this value so that they are encoded as
dictionaries.")

;;; Signing messages

(defun jupyter--sign-message (session parts)
  "Use SESSION to sign message PARTS.
Return the signature of PARTS. PARTS should be in the orde of a
valid Jupyter message, see `jupyter--decode-message'."
  (if (> (length (jupyter-session-key session)) 0)
      (cl-loop
       ;; NOTE: Encoding to a unibyte representation due to an "Attempt to
       ;; change byte length of a string" error.
       with key = (encode-coding-string
                   (jupyter-session-key session) 'utf-8 t)
       with parts = (encode-coding-string
                     (cl-loop
                      with parts = parts
                      repeat 4 concat (car parts)
                      and do (setq parts (cdr parts)))
                     'utf-8 t)
       for byte across (jupyter-hmac-sha256 parts key)
       concat (format "%02x" byte))
    ""))

(defun jupyter--split-identities (parts)
  "Extract the identities from a list of message PARTS."
  (let ((idents nil))
    (if (catch 'found-delim
          (while (car parts)
            (when (string= (car parts) jupyter-message-delimiter)
              (setq parts (cdr parts)
                    idents (nreverse idents))
              (throw 'found-delim t))
            (setq idents (cons (car parts) idents)
                  parts (cdr parts))))
        (cons idents parts)
      (error "Message delimiter not in message list"))))

(defun jupyter--message-header (session msg-type &optional msg-id)
  "Return a message header.
The `:session' key of the header will have its value set to
SESSION's ID, and its `:msg_type' will be set to MSG-TYPE. If
MSG-ID is non-nil it is set to the value of the `:msg_id' key,
otherwise a new message ID is generated. The other fields of the
returned plist are `:version', `:username', and `:date'. They are
all set to appropriate default values."
  (list
   :msg_id (or msg-id (jupyter-new-uuid))
   :msg_type msg-type
   :version jupyter-protocol-version
   :username user-login-name
   :session (jupyter-session-id session)
   :date (format-time-string "%FT%T.%6N%z" (current-time))))

;;; Encode/decoding messages

(defun jupyter--encode (part)
  "Encode PART into a JSON string.
Take into account `jupyter-message-type' keywords by replacing
them with their appropriate message type strings according to the
Jupyter messaging spec. After encoding into a JSON
representation, return the UTF-8 encoded string.

If PART is a string, return the UTF-8 encoded string without
encoding into JSON first.

If PART is a list whose first element is the symbol,
`message-part', then return the second element of the list if it
is non-nil. If it is nil, then set the list's second element to
the result of calling `jupyter--encode' on the third element and
return the result."
  ;; TODO: Handle date fields, they get turned into list
  (if (and (listp part) (eq (car part) 'message-part))
      (or (nth 1 part)
          (setf (nth 1 part) (jupyter--decode (nth 2 part))))
    (cl-letf (((symbol-function 'json-encode)
               (lambda (object)
                 (cond ((memq object (list t json-null json-false))
                        (json-encode-keyword object))
                       ((stringp object)      (json-encode-string object))
                       ((keywordp object)
                        ;; Handle `jupyter-message-type'
                        (let ((msg-type (plist-get jupyter-message-types object)))
                          (json-encode-string
                           (or msg-type (substring (symbol-name object) 1)))))
                       ((symbolp object)      (json-encode-string (symbol-name object)))
                       ((numberp object)      (json-encode-number object))
                       ((arrayp object)       (json-encode-array object))
                       ((hash-table-p object) (json-encode-hash-table object))
                       ((listp object)
                        (if (eq (car object) 'message-part)
                            (nth 1 object)
                          (json-encode-list object)))
                       (t                     (signal 'json-error (list object)))))))
      (encode-coding-string
       (cond
        ((stringp part) part)
        (t (json-encode part)))
       'utf-8 t))))

(defun jupyter--decode (part)
  "Decode a message PART.

If PART is a list whose first element is the symbol,
`message-part', then return the third element of the list if it
is non-nil. If it is nil, then set the list's third element to
the result of calling `jupyter--decode' on the second element and
return the result.

Otherwise, if PART is a string decode it using UTF-8 encoding and
read it as a JSON string. If it is not valid JSON, return the
decoded string."
  (if (and (listp part) (eq (car part) 'message-part))
      (or (nth 2 part)
          (setf (nth 2 part) (jupyter--decode (nth 1 part))))
    (let* ((json-object-type 'plist)
           (str (decode-coding-string part 'utf-8))
           (val (condition-case nil
                    (json-read-from-string str)
                  ;; If it can't be read as JSON, assume its just a regular
                  ;; string
                  (json-unknown-keyword str))))
      (prog1 val
        (when (listp val)
          (let ((date (plist-get val :date))
                (msg-type (plist-get val :msg_type)))
            ;; FIXME: Slow, the date field is not used anyways
            (when date
              (plist-put val :date (jupyter--decode-time date)))
            (when msg-type
              (plist-put val :msg_type
                         (jupyter-message-type-as-keyword msg-type)))))))))

(defun jupyter--decode-time (str)
  "Decode a time STR into a time object.
The returned object has the same form as the object returned by
`current-time'."
  (let ((usec 0))
    (when (string-match "\\(T\\).+\\(\\(?:\\.\\|,\\)[0-9]+\\)" str)
      (setq usec (ceiling (* 1000000 (string-to-number
                                      (match-string 2 str)))))
      (setq str (replace-match " " nil t str 1)))
    (nconc (apply #'encode-time (parse-time-string str))
           (list usec))))

(cl-defun jupyter--encode-message (session
                                   type
                                   &key idents
                                   content
                                   msg-id
                                   parent-header
                                   metadata
                                   buffers)
  (declare (indent 2))
  (cl-check-type session jupyter-session)
  (cl-check-type metadata json-plist)
  (cl-check-type content json-plist)
  (cl-check-type parent-header json-plist)
  (cl-check-type buffers list)
  (or content (setq content jupyter--empty-dict))
  (or parent-header (setq parent-header jupyter--empty-dict))
  (or metadata (setq metadata jupyter--empty-dict))

  (let* ((header (jupyter--message-header session type msg-id))
         (msg-id (plist-get header :msg_id))
         (parts (mapcar #'jupyter--encode (list header
                                           parent-header
                                           metadata
                                           content))))
    (cons msg-id
          (append
           (when idents (if (stringp idents) (list idents) idents))
           (list jupyter-message-delimiter
                 (jupyter--sign-message session parts))
           parts
           buffers))))

(defun jupyter--decode-message (session parts)
  "Use SESSION to decode message PARTS.
PARTS should be a list of message parts in the order of a valid
Jupyter message, i.e. a list of the form

    (signature header parent-header metadata content buffers...)

If SESSION supports signing messages, then the signature
resulting from signing of PARTS using SESSION should be equal to
SIGNATURE. An error is thrown if it is not.

The returned plist has elements of the form

    (message-part JSON PLIST)

for the keys `:header', `:parent-header', `:metadata',
`:content'. JSON is the JSON encoded string of the message part.
For `:header' and `:parent-header', PLIST will be the decoded
message PLIST for the part. The other message parts are decoded
into property lists on demand, i.e. after a call to
`jupyter-message-metadata' or `jupyter-message-content' PLIST
will be decoded message part.

The binary buffers are left unchanged and will be the value of
the `:buffers' key in the returned plist. Also, the message ID
and type are available in the top level of the plist as `:msg_id'
and `:msg_type'."
  (when (< (length parts) 5)
    (error "Malformed message. Minimum length of parts is 5"))
  (when (jupyter-session-key session)
    (let ((signature (car parts)))
      (when (= (length signature) 0)
        (error "Unsigned message"))
      ;; TODO: digest_history
      ;; https://github.com/jupyter/jupyter_client/blob/7a0278af7c1652ac32356d6f00ae29d24d78e61c/jupyter_client/session.py#L915
      (unless (string= (jupyter--sign-message session (cdr parts)) signature)
        (error "Invalid signature: %s" signature))))
  (cl-destructuring-bind
      (header parent-header metadata content &rest buffers)
      (cdr parts)
    (let ((dheader (jupyter--decode header)))
      (list
       :header `(message-part ,header ',dheader)
       :msg_id (plist-get dheader :msg_id)
       :msg_type (plist-get dheader :msg_type)
       ;; Also decode the parent header here since it is used quite often in
       ;; the parent Emacs process
       :parent_header `(message-part ,parent-header
                                     ,(jupyter--decode parent-header))
       :metadata `(message-part ,metadata nil)
       :content `(message-part ,content nil)
       :buffers buffers))))

;;; Sending/receiving

(cl-defmethod jupyter-send ((session jupyter-session)
                            socket
                            type
                            message
                            &optional
                            msg-id
                            flags)
  "For SESSION, send a message on SOCKET.
TYPE is message type of MESSAGE, one of the keys in
`jupyter-message-types'. MESSAGE is the message content.
Optionally supply a MSG-ID to the message, if this is nil a new
message ID will be generated. FLAGS has the same meaning as in
`zmq-send'. Return the message ID of the sent message."
  (declare (indent 1))
  (cl-destructuring-bind (id . msg)
      (jupyter--encode-message session type
        :msg-id msg-id :content message)
    (prog1 id
      (zmq-send-multipart socket msg flags))))

(cl-defmethod jupyter-recv ((session jupyter-session) socket &optional flags)
  "For SESSION, receive a message on SOCKET with FLAGS.
FLAGS is passed to SOCKET according to `zmq-recv'."
  (let ((msg (zmq-recv-multipart socket flags)))
    (when msg
      (cl-destructuring-bind (idents . parts)
          (jupyter--split-identities msg)
        (cons idents (jupyter--decode-message session parts))))))

;;; Control messages

(cl-defun jupyter-message-interrupt-request ()
  (list))

;;; stdin messages

(cl-defun jupyter-message-input-reply (&key value)
  (cl-check-type value string)
  (list :value value))

;;; shell messages

(cl-defun jupyter-message-kernel-info-request ()
  (list))

(cl-defun jupyter-message-execute-request (&key
                                           code
                                           (silent nil)
                                           (store-history t)
                                           (user-expressions nil)
                                           (allow-stdin t)
                                           (stop-on-error nil))
  (cl-check-type code string)
  (cl-check-type user-expressions json-plist)
  (list :code code :silent (if silent t jupyter--false)
        :store_history (if store-history t jupyter--false)
        :user_expressions (or user-expressions jupyter--empty-dict)
        :allow_stdin (if allow-stdin t jupyter--false)
        :stop_on_error (if stop-on-error t jupyter--false)))

(cl-defun jupyter-message-inspect-request (&key code pos detail)
  (setq detail (or detail 0))
  (unless (member detail '(0 1))
    (error "Detail can only be 0 or 1 (%s)" detail))
  (when (markerp pos)
    (setq pos (marker-position pos)))
  (cl-check-type code string)
  (cl-check-type pos integer)
  (list :code code :cursor_pos pos :detail_level detail))

(cl-defun jupyter-message-complete-request (&key code pos)
  (when (markerp pos)
    (setq pos (marker-position pos)))
  (cl-check-type code string)
  (cl-check-type pos integer)
  (list :code code :cursor_pos pos))

(cl-defun jupyter-message-history-request (&key
                                           output
                                           raw
                                           hist-access-type
                                           session
                                           start
                                           stop
                                           n
                                           pattern
                                           unique)
  (unless (member hist-access-type '("range" "tail" "search"))
    (error "History access type can only be one of (range, tail, search)"))
  (append
   (list :output (if output t jupyter--false) :raw (if raw t jupyter--false)
         :hist_access_type hist-access-type)
   (cond
    ((equal hist-access-type "range")
     (cl-check-type session integer)
     (cl-check-type start integer)
     (cl-check-type stop integer)
     (list :session session :start start :stop stop))
    ((equal hist-access-type "tail")
     (cl-check-type n integer)
     (list :n n))
    ((equal hist-access-type "search")
     (cl-check-type pattern string)
     (cl-check-type n integer)
     (list :pattern pattern :unique (if unique t jupyter--false) :n n)))))

(cl-defun jupyter-message-is-complete-request (&key code)
  (cl-check-type code string)
  (list :code code))

(cl-defun jupyter-message-comm-info-request (&key target-name)
  (when target-name
    (cl-check-type target-name string)
    (list :target_name target-name)))

(cl-defun jupyter-message-comm-open (&key id target-name data)
  (cl-check-type id string)
  (cl-check-type target-name string)
  (cl-check-type data json-plist)
  (list :comm_id id :target_name target-name :data data))

(cl-defun jupyter-message-comm-msg (&key id data)
  (cl-check-type id string)
  (cl-check-type data json-plist)
  (list :comm_id id :data data))

(cl-defun jupyter-message-comm-close (&key id data)
  (cl-check-type id string)
  (cl-check-type data json-plist)
  (list :comm_id id :data data))

(cl-defun jupyter-message-shutdown-request (&key restart)
  (list :restart (if restart t jupyter--false)))

;;; Convenience functions

(defmacro jupyter--decode-message-part (key msg)
  "Return a form to decode the value of KEY in MSG.
If the value of KEY is a list whose first element is the symbol
`message-part', then if the the third element of the list is nil
set it to the result of calling `jupyter--decode' on the second
element. If the third element is non-nil, return it. Otherwise
return the value of KEY in MSG."
  `(let ((part (plist-get ,msg ,key)))
     (if (and (listp part) (eq (car part) 'message-part))
         (or (nth 2 part) (jupyter--decode part))
       part)))

(defun jupyter-message-header (msg)
  "Get the header of MSG."
  (jupyter--decode-message-part :header msg))

(defun jupyter-message-parent-header (msg)
  "Get the parent header of MSG."
  (jupyter--decode-message-part :parent_header msg))

(defun jupyter-message-metadata (msg)
  "Get the metadata key of MSG."
  (jupyter--decode-message-part :metadata msg))

(defun jupyter-message-content (msg)
  "Get the MSG contents."
  (jupyter--decode-message-part :content msg))

(defun jupyter-message-id (msg)
  "Get the ID of MSG."
  (or (plist-get msg :msg_id)
      (plist-get (jupyter-message-header msg) :msg_id)))

(defun jupyter-message-parent-id (msg)
  "Get the parent ID of MSG."
  (jupyter-message-id (jupyter-message-parent-header msg)))

(defun jupyter-message-type (msg)
  "Get the type of MSG."
  (or (plist-get msg :msg_type)
      (plist-get (jupyter-message-header msg) :msg_type)))

(defun jupyter-message-session (msg)
  "Get the session ID of MSG."
  (plist-get (jupyter-message-header msg) :session))

(defun jupyter-message-parent-type (msg)
  "Get the type of MSG's parent message."
  (jupyter-message-type (jupyter-message-parent-header msg)))

(defun jupyter-message-type-as-keyword (msg-type)
  "Return MSG-TYPE as one of the keys in `jupyter-message-types'.
If MSG-TYPE is already a valid message type keyword, return it.
Otherwise return the MSG-TYPE string as a keyword."
  (if (keywordp msg-type)
      (if (plist-get jupyter-message-types msg-type) msg-type
        (error "Invalid message type (`%s')" msg-type))
    (let ((head jupyter-message-types)
          (tail (cdr jupyter-message-types)))
      (while (and head (not (string= msg-type (car tail))))
        (setq head (cdr tail)
              tail (cddr tail)))
      (unless head
        (error "Invalid message type (`%s')" msg-type))
      (car head))))

(defun jupyter-message-time (msg)
  "Get the MSG time.
The returned time has the same form as returned by
`current-time'."
  (plist-get (jupyter-message-header msg) :date))

(defun jupyter-message-get (msg key)
  "Get the value in MSG's `jupyter-message-content' that corresponds to KEY."
  (plist-get (jupyter-message-content msg) key))

(defun jupyter-message-data (msg mimetype)
  "Get the message data for a specific mimetype.
MSG should be a message with a `:data' field in its contents.
MIMETYPE is should be a standard media mimetype
keyword (`:text/plain', `:image/png', ...). If the messages data
has a key corresponding to MIMETYPE, return the value. Otherwise
return nil."
  (plist-get (jupyter-message-get msg :data) mimetype))

(defun jupyter-message-status-idle-p (msg)
  "Determine if MSG is a status: idle message."
  (and (eq (jupyter-message-type msg) :status)
       (equal (jupyter-message-get msg :execution_state) "idle")))

(defun jupyter-message-status-starting-p (msg)
  "Determine if MSG is a status: starting message."
  (and (eq (jupyter-message-type msg) :status)
       (equal (jupyter-message-get msg :execution_state) "starting")))

(provide 'jupyter-messages)

;;; jupyter-messages.el ends here

;; Local Variables:
;; byte-compile-warnings: (not free-vars)
;; End:
