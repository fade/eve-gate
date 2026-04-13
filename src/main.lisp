;;;; main.lisp - Main entry point and high-level interface for eve-gate

(in-package #:eve-gate)

;; Configuration constants
(defparameter *default-user-agent* eve-gate.core:*user-agent*
  "Default user-agent string. Delegates to the core module definition.")

;; Main client structure
(defclass eve-client ()
  ((http-client :initarg :http-client :reader eve-client-http-client)
   (auth-client :initarg :auth-client :reader eve-client-auth-client)
   (cache-manager :initarg :cache-manager :reader eve-client-cache-manager)
   (api-client :initarg :api-client :reader eve-client-api-client)
   (config :initarg :config :reader eve-client-config)
   (authenticated-p :initform nil :accessor client-authenticated-p))
  (:documentation "Main EVE Online ESI API client."))

(defun make-eve-client (&key config client-id client-secret redirect-uri)
  "Create a new EVE client instance with optional configuration."
  (let* ((final-config (merge-config config client-id client-secret redirect-uri))
         (http-client (eve-gate.core:make-http-client 
                      :timeout (or (get-config-value :default-timeout final-config) 30)
                      :retries (or (get-config-value :default-retries final-config) 3)
                      :middleware (eve-gate.core:make-default-middleware-stack)))
         (cache-manager (when (get-config-value :cache-enabled final-config)
                         (eve-gate.cache:make-cache-manager)))
         (auth-client (when (and client-id client-secret)
                       (eve-gate.auth:make-oauth-client
                        :client-id client-id
                        :client-secret client-secret
                        :redirect-uri redirect-uri)))
         (api-client (eve-gate.api:make-api-client
                      :http-client http-client
                      :cache-manager cache-manager
                      :base-url eve-gate.core:*esi-base-url*)))
    (make-instance 'eve-client
                   :http-client http-client
                   :auth-client auth-client
                   :cache-manager cache-manager
                   :api-client api-client
                   :config final-config)))

(defun merge-config (user-config client-id client-secret redirect-uri)
  "Merge user configuration with defaults and OAuth parameters."
  (let ((config (copy-list eve-gate.utils:*default-config*)))
    (when user-config
      (loop for (key value) on user-config by #'cddr
            do (setf (getf config key) value)))
    (when client-id (setf (getf config :client-id) client-id))
    (when client-secret (setf (getf config :client-secret) client-secret))
    (when redirect-uri (setf (getf config :redirect-uri) redirect-uri))
    config))

(defun authenticate-client (client authorization-code)
  "Authenticate the client using OAuth2 authorization code."
  (unless (eve-client-auth-client client)
    (error 'eve-gate.types:authentication-error 
           :message "Client not configured for authentication"))
  
  (let ((token (eve-gate.auth:exchange-code-for-token 
                (eve-client-auth-client client) 
                authorization-code)))
    (setf (client-authenticated-p client) t)
    ;; Store token in client or token manager
    (eve-gate.auth:store-token token)
    client))

(defun configure-client (client &key log-level cache-enabled debug-mode)
  "Reconfigure client settings at runtime."
  (let ((config (eve-client-config client)))
    (when log-level (setf (getf config :log-level) log-level))
    (when cache-enabled (setf (getf config :cache-enabled) cache-enabled))
    (when debug-mode (setf (getf config :debug-mode) debug-mode))
    client))

(defmacro with-client ((client-var &rest client-args) &body body)
  "Execute body with a configured EVE client."
  `(let ((,client-var (make-eve-client ,@client-args)))
     (unwind-protect
          (progn ,@body)
       ;; Cleanup if needed
       (when (eve-client-cache-manager ,client-var)
         (eve-gate.cache:cache-clear (eve-client-cache-manager ,client-var))))))

;; High-level API functions (stubs - will be generated from OpenAPI spec)
(defun get-character-public-info (client character-id)
  "Get public information about a character."
  (eve-gate.api:api-call (eve-client-api-client client)
                        (format nil "/characters/~A/" character-id)
                        :method :get))

(defun get-character-portrait (client character-id)
  "Get character portrait URLs."
  (eve-gate.api:api-call (eve-client-api-client client)
                        (format nil "/characters/~A/portrait/" character-id)
                        :method :get))

(defun get-corporation-info (client corporation-id)
  "Get public information about a corporation."
  (eve-gate.api:api-call (eve-client-api-client client)
                        (format nil "/corporations/~A/" corporation-id)
                        :method :get))

(defun get-alliance-info (client alliance-id)
  "Get public information about an alliance."
  (eve-gate.api:api-call (eve-client-api-client client)
                        (format nil "/alliances/~A/" alliance-id)
                        :method :get))

(defun get-system-info (client system-id)
  "Get information about a solar system."
  (eve-gate.api:api-call (eve-client-api-client client)
                        (format nil "/universe/systems/~A/" system-id)
                        :method :get))

(defun get-station-info (client station-id)
  "Get information about a station."
  (eve-gate.api:api-call (eve-client-api-client client)
                        (format nil "/universe/stations/~A/" station-id)
                        :method :get))

;; Bulk operations
(defun get-multiple-characters (client character-ids)
  "Get information for multiple characters in parallel."
  (eve-gate.concurrent:bulk-get client
                               (mapcar (lambda (id) 
                                        (format nil "/characters/~A/" id))
                                      character-ids)))

(defun get-multiple-corporations (client corporation-ids)
  "Get information for multiple corporations in parallel."
  (eve-gate.concurrent:bulk-get client
                               (mapcar (lambda (id)
                                        (format nil "/corporations/~A/" id))
                                      corporation-ids)))