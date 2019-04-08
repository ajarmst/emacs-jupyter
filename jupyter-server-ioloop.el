;;; jupyter-server-ioloop.el --- Server ioloop -*- lexical-binding: t -*-

;; Copyright (C) 2019 Nathaniel Nicandro

;; Author: Nathaniel Nicandro <nathanielnicandro@gmail.com>
;; Created: 03 Apr 2019
;; Version: 0.7.3

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
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

(require 'jupyter-ioloop)
(require 'jupyter-messages)
(require 'jupyter-rest-api)
(require 'websocket)

(defvar jupyter-server-recvd-messages nil)
(defvar jupyter-server-connected-kernels nil)

(defclass jupyter-server-ioloop (jupyter-ioloop)
  ()
  :documentation "A `jupyter-ioloop' configured for communication using websockets.

A websocket can be opened by sending the connect-channels event
with the websocket url and the kernel-id of the kernel to connect
to, e.g.

    \(jupyter-send ioloop 'connect-channels \"ws:localhost:8888\" \"kernel-id\")

Also implemented is the send event which takes the same arguments
as the send event of a `jupyter-channel-ioloop' except the
kernel-id must be the first element, e.g.

    \(jupyter-send ioloop 'send \"kernel-id\" ...)

Events that are emitted to the parent process are the message
event, also the same as the event in `jupyter-channel-ioloop'
except with a kernel-id as the first element. And a
disconnected-channels event that occurs whenever a websocket is
closed, the event has the kernel-id of the associated with the
websocket.")

(cl-defmethod initialize-instance ((ioloop jupyter-server-ioloop) &rest _)
  (cl-call-next-method)
  (cl-callf append (oref ioloop setup)
    `((push ,(file-name-directory (locate-library "websocket")) load-path)
      (require 'jupyter-server-ioloop)
      (push 'jupyter-server-ioloop--recv-messages jupyter-ioloop-pre-hook)))
  (jupyter-server-ioloop-add-send-event ioloop)
  (jupyter-server-ioloop-add-connect-channels-event ioloop)
  (jupyter-server-ioloop-add-disconnect-channels-event ioloop))

;;; Receiving messages on a websocket

;; Added to `jupyter-ioloop-pre-hook'
(defun jupyter-server-ioloop--recv-messages ()
  ;; A negative value of seconds means to return immediately if there was
  ;; nothing that could be read from subprocesses. See `Faccept_process_output'
  ;; and `wait_reading_process_output'.
  (accept-process-output nil -1)
  (when jupyter-server-recvd-messages
    (mapc (lambda (msg) (prin1 (cons 'message msg)))
       (nreverse jupyter-server-recvd-messages))
    (setq jupyter-server-recvd-messages nil)
    (zmq-flush 'stdout)))

(defun jupyter-server-ioloop--on-message (ws frame)
  (condition-case err
      (progn
        (cl-assert (eq (websocket-frame-opcode frame) 'text))
        (let* ((msg (jupyter-read-plist-from-string
                     (websocket-frame-payload frame)))
               (channel (intern (concat ":" (plist-get msg :channel))))
               (msg-type (jupyter-message-type-as-keyword
                          (jupyter-message-type msg)))
               (parent-header (plist-get msg :parent_header)))
          ;; Convert into keyword since that is what is expected
          (plist-put msg :msg_type msg-type)
          (plist-put parent-header :msg_type msg-type)
          ;; websocket-client-data = kernel-id
          (push (cons (websocket-client-data ws)
                      ;; NOTE: The nil is the identity field expected by a
                      ;; `jupyter-channel-ioloop', it is mimicked here.
                      (cons channel (cons nil msg)))
                jupyter-server-recvd-messages)))
    (error
     (zmq-prin1 (cons 'error (list (car err)
                                   (format "%S" (cdr err))))))))

(defun jupyter-server-ioloop--disconnect (ws)
  (let ((kernel-id (websocket-client-data ws)))
    (zmq-prin1 (list 'disconnected-channels kernel-id))
    (cl-callf2 delq ws jupyter-server-connected-kernels)))

(defun jupyter-server-ioloop--kernel-ws (kernel-id)
  (cl-find-if
   (lambda (ws) (equal kernel-id (websocket-client-data ws)))
   jupyter-server-connected-kernels))

;;; IOLoop events

(defvar jupyter-server--dummy-session (jupyter-session :id ""))

(defun jupyter-server-ioloop-add-send-event (ioloop)
  (jupyter-ioloop-add-event
      ioloop send (kernel-id channel msg-type msg msg-id)
    (let ((ws (jupyter-server-ioloop--kernel-ws kernel-id)))
      (unless ws
        (error "Kernel with ID (%s) not connected" kernel-id))
      (if (not (websocket-openp ws))
          (jupyter-server-ioloop--disconnect ws)
        (websocket-send-text
         ws (jupyter-encode-raw-message
                jupyter-server--dummy-session msg-type
              :channel (substring (symbol-name channel) 1)
              :msg-id msg-id
              :content msg))
        (list 'sent kernel-id channel msg-id)))))

(defun jupyter-server-ioloop-add-connect-channels-event (ioloop)
  (jupyter-ioloop-add-event ioloop connect-channels (ws-url kernel-id)
    (let ((ws (jupyter-server-ioloop--kernel-ws kernel-id)))
      (when (and ws (not (websocket-openp ws)))
        ;; Delete the process if not already
        (websocket-close ws)
        (setq ws nil))
      (unless ws
        (push
         (jupyter-api-kernel-ws
          (jupyter-rest-client :ws-url ws-url) kernel-id
          :on-close #'jupyter-server-ioloop--disconnect
          :on-message #'jupyter-server-ioloop--on-message)
         jupyter-server-connected-kernels)))
    (list 'connect-channels kernel-id)))

(defun jupyter-server-ioloop-add-disconnect-channels-event (ioloop)
  (jupyter-ioloop-add-event ioloop disconnect-channels (kernel-id)
    (let ((ws (jupyter-server-ioloop--kernel-ws kernel-id)))
      (if ws (websocket-close ws)
        (list 'disconnect-channels kernel-id)))))

(provide 'jupyter-server-ioloop)

;;; jupyter-server-ioloop.el ends here
