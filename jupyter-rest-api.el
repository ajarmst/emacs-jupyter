;;; jupyter-rest-api.el --- Jupyter REST API -*- lexical-binding: t -*-

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

;; Routines for working with the Jupyter REST API. Currently only the
;; api/kernels and api/kernelspecs endpoints are implemented.

;;; Code:

(require 'jupyter-base)
(require 'websocket)

(declare-function url-digest-auth "url-auth")

(defgroup jupyter-rest-api nil
  "Jupyter REST API"
  :group 'jupyter)

(defmacro jupyter-with-api (client &rest body)
  "Bind `jupyter-api-url' to the url slot of CLIENT, evaluate BODY."
  (declare (indent 1))
  `(let ((jupyter-api-url (oref ,client url)))
     ,@body))

(defvar jupyter-api-url nil
  "The URL used for requests by `jupyter-api--request'.")

;;; Jupyter REST API

(defvar url-http-end-of-headers)
(defvar url-http-response-status)
(defvar gnutls-verify-error)

(defclass jupyter-rest-client ()
  ((url :type string :initform "http://localhost:8888" :initarg :url)
   (ws-url :type string :initform "ws://localhost:8888" :initarg :ws-url)
   ;; TODO: An alternative is to set the user and password in ~/.authinfo.gpg
   ;; in that case, the auth information is automatically appended to the
   ;; request.
   (authenticate :type boolean :initform nil :initarg :authenticate)))

(defun jupyter-api--get-auth (client)
  "Return the value of the Authentication header to use for CLIENT."
  ;; TODO: Look into (url-get-authentication)
  (url-digest-auth
   (oref client url) 'prompt nil
   (oref client url) `(("nonce" . ,(sha1 (number-to-string (random)))))))

;; TODO: Consider security
;; May be of interest https://nullprogram.com/blog/2016/06/16/
;; TODO: `url-digest-auth'
;; (list (cons "Authorization" (url-digest-auth url 'prompt 'overwrite)))
(defun jupyter-api-http-request (url endpoint method &rest data)
  "Send request to URL/ENDPOINT using HTTP METHOD.
DATA is encoded into a JSON string using `json-encode' and sent
as the HTTP request data. If DATA is nil, don't send any
request data."
  (declare (indent 3))
  (let* ((url-request-method method)
         (url-request-data (and data (json-encode data)))
         (url-request-extra-headers
          (append
           (when url-request-data
             (list (cons "Content Type" "application/json")))
           url-request-extra-headers))
         ;; Prevent the connection if security checks fail
         (gnutls-verify-error t))
    (with-current-buffer (url-retrieve-synchronously
                          (concat url "/" endpoint)
                          t t jupyter-long-timeout)
      (goto-char url-http-end-of-headers)
      (skip-syntax-forward "->")
      (unless (eobp)
        (let* ((json-object-type 'plist)
               (resp (ignore-errors (json-read))))
          (cond
           ((>= url-http-response-status 400)
            (cl-destructuring-bind
                (&key reason message traceback &allow-other-keys) resp
              (if traceback
                  (error "%s (%s): %s" reason message
                         (car (last (split-string traceback "\n" 'omitnulls))))
                (error "%s (%s)" reason message))))
           (t
            resp)))))))

;;; Calling the REST API

(defun jupyter-api--request (method &rest plist)
  "Send an HTTP request to `jupyter-api-url'.
METHOD is the HTTP request method and PLIST contains the request.
The elements of PLIST before the first keyword form the REST api
endpoint and the rest of the PLIST after will be encoded into a
JSON object and sent as the request data if METHOD is POST. So a
call like

    \(let ((jupyter-api-url \"http://localhost:8888\"))
       (jupyter-api--request \"POST\" \"kernels\" :name \"python\"))

will create an http POST request to the url
http://localhost:8888/api/kernels using the JSON encoded from the
plist (:name \"python\") as the POST data.

As a special case, if METHOD is \"WS\", a websocket will be
opened using the REST api url and PLIST will be used in a call to
`websocket-open'."
  (let (endpoint)
    (while (and plist (not (or (keywordp (car plist))
                               (null (car plist)))))
      (push (pop plist) endpoint))
    (setq endpoint (nreverse endpoint))
    (cl-assert (not (null endpoint)))
    (cl-assert (not (null jupyter-api-url)))
    (setq endpoint (mapconcat #'identity (cons "api" endpoint) "/"))
    (pcase method
      ("WS"
       (apply #'websocket-open
              (concat jupyter-api-url "/" endpoint)
              plist))
      (_
       (apply #'jupyter-api-http-request
              jupyter-api-url endpoint method
              plist)))))

(cl-defgeneric jupyter-api-request ((client jupyter-rest-client) method &rest plist)
  (declare (indent 2)))

(cl-defmethod jupyter-api-request ((client jupyter-rest-client) method &rest plist)
  "Send an HTTP request using CLIENT.
METHOD is the HTTP request method and PLIST contains the request.
The elements of PLIST before the first keyword form the REST api
endpoint and the rest of the PLIST after will be encoded into a
JSON object and sent as the request data. So a call like

   \(jupyter-api-request client \"POST\" \"kernels\" :name \"python\")

where the url slot of client is http://localhost:8888 will create
an http POST request to the url http://localhost:8888/api/kernels
using the JSON encoded from the plist (:name \"python\") as the
POST data.

Note an empty plist (after forming the endpoint) is interpreted
as no request data at all and NOT as an empty JSON dictionary.

As a special case, if METHOD is \"WS\", a websocket will be
opened using the REST api url and PLIST will be used in a call to
`websocket-open'."
  (let ((url-request-extra-headers
         (append
          (when (oref client authenticate)
            (list (cons "Authentication" (jupyter-api--get-auth client))))
          url-request-extra-headers))
        (jupyter-api-url
         (slot-value client (pcase method
                              ("WS" 'ws-url)
                              (_ 'url)))))
    (apply #'jupyter-api--request method plist)))

(cl-defmethod jupyter-api/kernels ((client jupyter-rest-client) method &rest plist)
  "Send an HTTP request to the api/kernels endpoint to CLIENT's url.
METHOD is the HTTP method to use. PLIST has the same meaning as
in `jupyter-api-request'."
  (apply #'jupyter-api-request client method "kernels" plist))

(cl-defmethod jupyter-api/kernelspecs ((client jupyter-rest-client) method &rest plist)
  "Send an HTTP request to the api/kernelspecs endpoint of CLIENT.
METHOD is the HTTP method to use. PLIST has the same meaning as
in `jupyter-api-request'."
  (apply #'jupyter-api-request client method "kernelspecs" plist))

;;; Kernels API

(defun jupyter-api-get-kernel (client &optional id)
  "Send an HTTP request using CLIENT to return a plist of the kernel with ID.
If ID is nil, return models for all kernels accessible via CLIENT."
  (jupyter-api/kernels client "GET" id))

(defun jupyter-api-start-kernel (client &optional name)
  "Send an HTTP request using CLIENT to start a kernel with kernelspec NAME.
If NAME is not provided use the default kernelspec."
  (apply #'jupyter-api/kernels client "POST"
         (when name (list :name name))))

(defun jupyter-api-shutdown-kernel (client id)
  "Send the HTTP request using CLIENT to shutdown a kernel with ID."
  (jupyter-api/kernels client "DELETE" id))

(defun jupyter-api-restart-kernel (client id)
  "Send an HTTP request using CLIENT to restart a kernel with ID."
  (jupyter-api/kernels client "POST" id "restart"))

(defun jupyter-api-interrupt-kernel (client id)
  "Send an HTTP request using CLIENT to interrupt a kernel with ID."
  (jupyter-api/kernels client "POST" id "interrupt"))

;;;; Kernel websocket

(defun jupyter-api-kernel-ws (client id &rest plist)
  "Return a websocket using CLIENT's ws-url slot.
ID identifies the kernel to connect to, PLIST will be passed to
the call to `websocket-open' to initialize the websocket.

Note, ID is also stored as the `websocket-client-data' slot of
the returned websocket."
  (let ((ws (apply #'jupyter-api/kernels client "WS" id "channels" plist)))
    (prog1 ws
      (setf (websocket-client-data ws) id))))

;;; Kernelspec API

(defun jupyter-api-get-kernelspec (client &optional name)
  "Send an HTTP request using CLIENT to get the kernelspec with NAME.
If NAME is not provided, return a plist of all kernelspecs
available via CLIENT."
  (apply #'jupyter-api/kernelspecs client "GET"
         (when name (list :name name))))

;;; Shutdown/interrupt kernel

(cl-defmethod jupyter-shutdown-kernel ((client jupyter-rest-client) kernel-id
                                       &optional restart timeout)
  "Send an HTTP request using CLIENT to shutdown the kernel with KERNEL-ID.
Optionally RESTART the kernel. If TIMEOUT is provided, it is the
timeout used for the HTTP request."
  (let ((jupyter-long-timeout (or timeout jupyter-long-timeout)))
    (if restart (jupyter-api-restart-kernel client kernel-id)
      (jupyter-api-shutdown-kernel client kernel-id))))

(cl-defmethod jupyter-interrupt-kernel ((client jupyter-rest-client) kernel-id
                                        &optional timeout)
  "Send an HTTP request using CLIENT to interrupt the kernel with KERNEL-ID.
If TIMEOUT is provided, it is the timeout used for the HTTP
request."
  (let ((jupyter-long-timeout (or timeout jupyter-long-timeout)))
    (jupyter-api-interrupt-kernel client kernel-id)))

(provide 'jupyter-rest-api)

;;; jupyter-rest-api.el ends here
