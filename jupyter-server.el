;;; jupyter-server.el --- Support for the Jupyter kernel servers -*- lexical-binding: t -*-

;; Copyright (C) 2019 Nathaniel Nicandro

;; Author: Nathaniel Nicandro <nathanielnicandro@gmail.com>
;; Created: 02 Apr 2019
;; Version: 0.8.0

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

;; A `jupyter-server' communicates with a Jupyter kernel server (either the
;; notebook or a kernel gateway) via the Jupyter REST API. Given the URL and
;; Websocket URL for the server, the `jupyter-server' object can launch kernels
;; using the function `jupyter-server-start-new-kernel'. You can access the
;; kernelspecs that can be launched on the server by calling
;; `jupyter-server-kernelspecs'.
;;
;; `jupyter-server-start-new-kernel' returns a list (KM KC) where KM is a
;; `jupyter-server-kernel-manager' and KC is a kernel client that can
;; communicate with the kernel managed by KM. `jupyter-server-kernel-manager'
;; sends requests to the server using the `jupyter-server' object to manage the
;; lifetime of the kernel and ensures that a websocket is opened so that
;; kernel clients can communicate with the kernel.
;;
;; `jupyter-server-kernel-comm' is a `jupyter-comm-layer' that handles the
;; communication of a kernel client with the kernel. The `jupyter-server' is
;; also a `jupyter-comm-layer' that receives and sends kernel messages from/to
;; the server. The job of the `jupyter-server-kernel-comm' is to connect to the
;; `jupyter-server's event stream and filter the messages to handle those of a
;; particular kernel identified through the kernel ID received by the server
;; when starting the kernel.

;;; Code:

(eval-when-compile (require 'subr-x))
(require 'jupyter-rest-api)
(require 'jupyter-kernel-manager)
(require 'jupyter-comm-layer)
(require 'jupyter-server-ioloop)

(defgroup jupyter-server nil
  "Support for the Jupyter kernel gateway"
  :group 'jupyter)

(defclass jupyter-server (jupyter-rest-client jupyter-ioloop-comm)
  ((kernelspecs
    :type json-plist
    :initform nil
    :documentation "Kernelspecs for the kernels available behind this gateway.
Access should be done through `jupyter-available-kernelspecs'.")))

;;; `jupyter-server-kernel'

;; TODO: Add the server as a slot
(defclass jupyter-server-kernel (jupyter-meta-kernel)
  ((id
    :type string
    :documentation "The kernel ID.")))

(cl-defmethod jupyter-kernel-alive-p ((kernel jupyter-server-kernel))
  (slot-boundp kernel 'id))

(cl-defmethod jupyter-start-kernel ((kernel jupyter-server-kernel) server &rest _ignore)
  (cl-check-type server jupyter-server)
  (with-slots (spec) kernel
    (jupyter-server--verify-kernelspec server spec)
    (cl-destructuring-bind (&key id &allow-other-keys)
        (jupyter-api-start-kernel server (car spec))
      (oset kernel id id))))

(cl-defmethod jupyter-kill-kernel ((kernel jupyter-server-kernel))
  (cl-call-next-method)
  (slot-makeunbound kernel 'id))

;;; `jupyter-server-kernel-comm'

(defclass jupyter-server-kernel-comm (jupyter-comm-layer)
  ((server :type jupyter-server :initarg :server)
   (kernel :type jupyter-server-kernel :initarg :kernel)))

(cl-defmethod initialize-instance ((comm jupyter-server) &optional _slots)
  (cl-call-next-method)
  (oset comm ioloop (jupyter-server-ioloop)))

(cl-defmethod jupyter-connect-client ((comm jupyter-server)
                                      (kcomm jupyter-server-kernel-comm))
  (with-slots (id) (oref kcomm kernel)
    (cl-call-next-method)
    (jupyter-send comm 'connect-channels (oref comm ws-url) id)
    (unless (jupyter-ioloop-wait-until (oref comm ioloop)
                'connect-channels #'identity)
      (error "Timeout when connecting websocket to kernel id %s" id))))

(cl-defmethod jupyter-server-kernel-connected-p ((comm jupyter-server) id)
  (and (jupyter-comm-alive-p comm)
       (member id (process-get (oref (oref comm ioloop) process) :kernel-ids))))

(defun jupyter-server--verify-kernelspec (server spec)
  (cl-destructuring-bind (name _ . kspec) spec
    (let ((server-spec (assoc name (jupyter-server-kernelspecs server))))
      (unless server-spec
        (error "No kernelspec matching %s on server @ %s"
               name (oref server url)))
      (when (cl-loop
             with sspec = (cddr server-spec)
             for (k v) on sspec by #'cddr
             thereis (not (equal (plist-get kspec k) v)))
        (error "%s kernelspec doesn't match one on server @ %s"
               name (oref server url))))))

(cl-defmethod jupyter-server-kernelspecs ((server jupyter-server) &optional refresh)
  "Return the kernelspecs on SERVER.
By default the available kernelspecs are cached. To force an
update of the cached kernelspecs, give a non-nil value to
REFRESH.

The kernelspecs are returned in the same form as returned by
`jupyter-available-kernelspecs'."
  (when (or refresh (null (oref server kernelspecs)))
    (let ((specs (jupyter-api-get-kernelspec server)))
      (unless specs
        (error "Can't retrieve kernelspecs from server @ %s" (oref server url)))
      (oset server kernelspecs specs)
      (plist-put (oref server kernelspecs) :kernelspecs
                 (cl-loop
                  with specs = (plist-get specs :kernelspecs)
                  for (_ spec) on specs by #'cddr
                  ;; Uses the same format as `jupyter-available-kernelspecs'
                  ;;     (name dir . spec)
                  collect (cons (plist-get spec :name)
                                (cons nil (plist-get spec :spec)))))))
  (plist-get (oref server kernelspecs) :kernelspecs))

;; TODO: Test this
(cl-defmethod jupyter-event-handler ((comm jupyter-server)
                                     (event (head disconnect-channels)))
  (let ((kernel-id (cadr event)))
    (jupyter-comm-client-loop comm client
      (when (equal kernel-id (oref (oref client kernel) id))
        (jupyter-disconnect-client comm client)))
    (with-slots (ioloop) comm
      (cl-callf2 remove kernel-id
                 (process-get (oref ioloop process) :kernel-ids)))))

(cl-defmethod jupyter-event-handler ((comm jupyter-server)
                                     (event (head connect-channels)))
  (let ((kernel-id (cadr event)))
    (with-slots (ioloop) comm
      (cl-callf append (process-get (oref ioloop process) :kernel-ids)
        (list kernel-id)))))

(cl-defmethod jupyter-event-handler ((comm jupyter-server) event)
  (let ((kernel-id (cadr event)))
    (setq event (cons (car event) (cddr event)))
    (jupyter-comm-client-loop comm client
      (when (equal kernel-id (oref (oref client kernel) id))
        (run-at-time 0 nil #'jupyter-event-handler client event)))))

(cl-defmethod jupyter-comm-start ((comm jupyter-server-kernel-comm) &rest _ignore)
  (jupyter-comm-start (oref comm server))
  (jupyter-connect-client (oref comm server) comm))

(cl-defmethod jupyter-comm-stop ((comm jupyter-server-kernel-comm) &rest _ignore)
  (jupyter-disconnect-client (oref comm server) comm))

(cl-defmethod jupyter-send ((comm jupyter-server-kernel-comm) event-type &rest event)
  (with-slots (server kernel) comm
    (apply #'jupyter-send server event-type (oref kernel id) event)))

(cl-defmethod jupyter-comm-alive-p ((comm jupyter-server-kernel-comm))
  (and (jupyter-server-kernel-connected-p
        (oref comm server)
        (oref (oref comm kernel) id))
       (catch 'member
         (jupyter-comm-client-loop (oref comm server) client
           (when (eq client comm)
             (throw 'member t))))))

;; TODO: Remove the need for these methods, they are remnants from an older
;; implementation. They will need to be removed from `jupyter-kernel-client'.
(cl-defmethod jupyter-channel-alive-p ((comm jupyter-server-kernel-comm) _channel)
  (jupyter-comm-alive-p comm))

(cl-defmethod jupyter-channels-running-p ((comm jupyter-server-kernel-comm))
  (jupyter-comm-alive-p comm))

;;; `jupyter-server-kernel-manager'

;; TODO: Generalize `jupyter-kernel-manager' some more so that it can be
;; sub-classed.
(defclass jupyter-server-kernel-manager (jupyter-kernel-lifetime)
  ((server :type jupyter-server :initarg :server)
   (kernel :type jupyter-server-kernel :initarg :kernel)
   (comm :type jupyter-server-kernel-comm)))

(cl-defmethod jupyter-kernel-alive-p ((manager jupyter-server-kernel-manager))
  (with-slots (server kernel) manager
    (and (jupyter-kernel-alive-p kernel)
         (ignore-errors (jupyter-api-get-kernel server (oref kernel id))))))

(cl-defmethod jupyter-start-kernel ((manager jupyter-server-kernel-manager) &rest _ignore)
  "Ensure that the gateway can receive events from its kernel."
  (with-slots (server kernel) manager
    (jupyter-start-kernel kernel server)))

(cl-defmethod jupyter-kill-kernel ((manager jupyter-server-kernel-manager))
  (jupyter-shutdown-kernel manager))

(cl-defmethod jupyter-shutdown-kernel ((manager jupyter-server-kernel-manager) &rest _args)
  (with-slots (server kernel comm) manager
    (jupyter-api-shutdown-kernel server (oref kernel id))
    (jupyter-comm-stop comm)))

(cl-defmethod jupyter-make-client ((manager jupyter-server-kernel-manager) _class &rest _slots)
  (let ((client (cl-call-next-method)))
    (prog1 client
      ;; TODO: What are the GC consequences
      (unless (slot-boundp manager 'comm)
        (oset manager comm (jupyter-server-kernel-comm
                            :kernel (oref manager kernel)
                            :server (oref manager server)))
        (jupyter-comm-start (oref manager comm)))
      (oset client kcomm (oref manager comm)))))

;;; REPL

(require 'jupyter-repl)

;; TODO: When closing the REPL buffer and it is the last connected client as
;; shown by the :connections key of a `jupyter-api-get-kernel' call, ask to
;; also shutdown the kernel.
(defun jupyter-server-start-new-kernel (server kernel-name &optional client-class)
  "Start a managed Jupyter kernel on SERVER.
KERNEL-NAME is the name of the kernel to start. It can also be
the prefix of a valid kernel name, in which case the first kernel
in ‘jupyter-server-kernelspecs’ that has KERNEL-NAME as a
prefix will be used.

Optional argument CLIENT-CLASS is a subclass
of ‘jupyer-kernel-client’ and will be used to initialize a new
client connected to the kernel. CLIENT-CLASS defaults to the
symbol ‘jupyter-kernel-client’.

Return a list (KM KC) where KM is the kernel manager managing the
lifetime of the kernel on SERVER. KC is a new client connected to
the kernel whose class is CLIENT-CLASS. Note that the client’s
‘manager’ slot will also be set to the kernel manager instance,
see ‘jupyter-make-client’."
  (or client-class (setq client-class 'jupyter-kernel-client))
  (jupyter-error-if-not-client-class-p client-class)
  (let* ((specs (jupyter-server-kernelspecs server))
         (manager (jupyter-server-kernel-manager
                   :server server
                   :kernel (jupyter-server-kernel
                            :spec (jupyter-guess-kernelspec kernel-name specs)))))
    (jupyter-start-kernel manager)
    (let ((client (jupyter-make-client manager client-class)))
      (jupyter-start-channels client)
      (list manager client))))

(defun jupyter-guess-server ()
  (let ((servers (cl-loop
                  for client in (jupyter-clients)
                  when (and (oref client manager)
                            (cl-typep (oref client manager)
                                      'jupyter-server-kernel-manager))
                  collect (oref (oref client manager) server))))
    (if (> (length servers) 1)
        (cdr (completing-read "Server: " (mapcar (lambda (x) (cons (oref x url) x)) servers)))
      (or (car servers)
          (let ((url (read-string "Server URL: " "https://127.0.0.1:8888"))
                (ws-url (read-string "Websocket URL: " "ws://127.0.0.1:8888")))
            (jupyter-server :url url :ws-url ws-url))))))

;;;###autoload
(defun jupyter-run-server-repl
    (server kernel-name &optional repl-name associate-buffer client-class display)
  "Run a REPL on SERVER."
  (interactive
   (let ((server (jupyter-guess-server)))
     (list server
           (car (jupyter-completing-read-kernelspec
                 (jupyter-server-kernelspecs server)))
           (when current-prefix-arg
             (read-string "REPL Name: "))
           t nil t)))
  (or client-class (setq client-class 'jupyter-repl-client))
  (unless (child-of-class-p client-class 'jupyter-repl-client)
    (error "Class should be a subclass of `jupyter-repl-client' (`%s')" client-class))
  (cl-destructuring-bind (_manager client)
      (jupyter-server-start-new-kernel server kernel-name client-class)
    ;; TODO: Rename to `jupyter-bootstrap-repl'
    (jupyter-repl--new-repl client repl-name)
    (when (and associate-buffer
               (eq major-mode (jupyter-kernel-language-mode client)))
      (jupyter-repl-associate-buffer client))
    (when display
      (pop-to-buffer (oref client buffer)))
    client))

(provide 'jupyter-server)

;;; jupyter-server.el ends here
