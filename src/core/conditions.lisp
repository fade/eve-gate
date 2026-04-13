;;;; conditions.lisp - ESI-specific condition hierarchy for eve-gate
;;;;
;;;; Defines the condition system for the ESI API client. Uses the Common Lisp
;;;; condition system with restarts for sophisticated error recovery. Conditions
;;;; map ESI HTTP responses to meaningful, actionable errors.
;;;;
;;;; The hierarchy is:
;;;;   esi-condition (warning)
;;;;     esi-deprecation-warning
;;;;   esi-error (error)
;;;;     esi-client-error (4xx)
;;;;       esi-bad-request (400)
;;;;       esi-unauthorized (401)
;;;;       esi-forbidden (403)
;;;;       esi-not-found (404)
;;;;       esi-rate-limit-exceeded (420)
;;;;       esi-unprocessable-entity (422)
;;;;     esi-server-error (5xx)
;;;;       esi-internal-error (500)
;;;;       esi-bad-gateway (502)
;;;;       esi-service-unavailable (503)
;;;;       esi-gateway-timeout (504)
;;;;     esi-network-error
;;;;       esi-connection-timeout
;;;;       esi-read-timeout

(in-package #:eve-gate.core)

;;; ---------------------------------------------------------------------------
;;; Base conditions
;;; ---------------------------------------------------------------------------

(define-condition esi-condition (warning)
  ((message :initarg :message
            :initform ""
            :reader esi-condition-message)
   (endpoint :initarg :endpoint
             :initform nil
             :reader esi-condition-endpoint))
  (:documentation "Base warning condition for ESI-related warnings.")
  (:report (lambda (condition stream)
             (format stream "ESI Warning~@[ (~A)~]: ~A"
                     (esi-condition-endpoint condition)
                     (esi-condition-message condition)))))

(define-condition esi-deprecation-warning (esi-condition)
  ((alternate-route :initarg :alternate-route
                    :initform nil
                    :reader esi-deprecation-alternate-route))
  (:documentation "Signaled when an ESI endpoint is deprecated.")
  (:report (lambda (condition stream)
             (format stream "ESI Deprecation~@[ (~A)~]: ~A~@[~%Use alternate route: ~A~]"
                     (esi-condition-endpoint condition)
                     (esi-condition-message condition)
                     (esi-deprecation-alternate-route condition)))))

;;; ---------------------------------------------------------------------------
;;; Error conditions
;;; ---------------------------------------------------------------------------

(define-condition esi-error (error)
  ((status-code :initarg :status-code
                :initform nil
                :reader esi-error-status-code)
   (message :initarg :message
            :initform "Unknown ESI error"
            :reader esi-error-message)
   (endpoint :initarg :endpoint
             :initform nil
             :reader esi-error-endpoint)
   (response-body :initarg :response-body
                  :initform nil
                  :reader esi-error-response-body)
   (response-headers :initarg :response-headers
                     :initform nil
                     :reader esi-error-response-headers))
  (:documentation "Base error condition for all ESI API errors.")
  (:report (lambda (condition stream)
             (format stream "ESI Error~@[ ~D~]~@[ (~A)~]: ~A"
                     (esi-error-status-code condition)
                     (esi-error-endpoint condition)
                     (esi-error-message condition)))))

;;; --- Client errors (4xx) ---

(define-condition esi-client-error (esi-error)
  ()
  (:documentation "Condition for ESI 4xx client errors."))

(define-condition esi-bad-request (esi-client-error)
  ()
  (:default-initargs :status-code 400 :message "Bad request"))

(define-condition esi-unauthorized (esi-client-error)
  ()
  (:default-initargs :status-code 401 :message "Unauthorized - invalid or missing token"))

(define-condition esi-forbidden (esi-client-error)
  ((required-scope :initarg :required-scope
                   :initform nil
                   :reader esi-forbidden-required-scope))
  (:default-initargs :status-code 403 :message "Forbidden - insufficient scope or permission")
  (:report (lambda (condition stream)
             (format stream "ESI Forbidden (~A): ~A~@[~%Required scope: ~A~]"
                     (esi-error-endpoint condition)
                     (esi-error-message condition)
                     (esi-forbidden-required-scope condition)))))

(define-condition esi-not-found (esi-client-error)
  ()
  (:default-initargs :status-code 404 :message "Resource not found"))

(define-condition esi-rate-limit-exceeded (esi-client-error)
  ((retry-after :initarg :retry-after
                :initform nil
                :reader esi-rate-limit-retry-after)
   (error-limit-remain :initarg :error-limit-remain
                       :initform nil
                       :reader esi-rate-limit-error-limit-remain)
   (error-limit-reset :initarg :error-limit-reset
                      :initform nil
                      :reader esi-rate-limit-error-limit-reset))
  (:default-initargs :status-code 420 :message "Error rate limit exceeded")
  (:report (lambda (condition stream)
             (format stream "ESI Rate Limited (~A): ~A~@[~%Retry after: ~A seconds~]~@[~%Error limit remaining: ~A~]"
                     (esi-error-endpoint condition)
                     (esi-error-message condition)
                     (esi-rate-limit-retry-after condition)
                     (esi-rate-limit-error-limit-remain condition)))))

(define-condition esi-unprocessable-entity (esi-client-error)
  ()
  (:default-initargs :status-code 422 :message "Unprocessable entity"))

;;; --- Server errors (5xx) ---

(define-condition esi-server-error (esi-error)
  ()
  (:documentation "Condition for ESI 5xx server errors."))

(define-condition esi-internal-error (esi-server-error)
  ()
  (:default-initargs :status-code 500 :message "ESI internal server error"))

(define-condition esi-bad-gateway (esi-server-error)
  ()
  (:default-initargs :status-code 502 :message "ESI bad gateway"))

(define-condition esi-service-unavailable (esi-server-error)
  ()
  (:default-initargs :status-code 503 :message "ESI service unavailable"))

(define-condition esi-gateway-timeout (esi-server-error)
  ()
  (:default-initargs :status-code 504 :message "ESI gateway timeout"))

;;; --- Network errors ---

(define-condition esi-network-error (esi-error)
  ((original-condition :initarg :original-condition
                       :initform nil
                       :reader esi-network-error-original-condition))
  (:documentation "Condition for network-level errors (timeouts, connection failures).")
  (:default-initargs :message "Network error"))

(define-condition esi-connection-timeout (esi-network-error)
  ((timeout-seconds :initarg :timeout-seconds
                    :initform nil
                    :reader esi-connection-timeout-seconds))
  (:default-initargs :message "Connection timed out")
  (:report (lambda (condition stream)
             (format stream "ESI Connection Timeout~@[ (~A)~]~@[: ~A seconds~]"
                     (esi-error-endpoint condition)
                     (esi-connection-timeout-seconds condition)))))

(define-condition esi-read-timeout (esi-network-error)
  ((timeout-seconds :initarg :timeout-seconds
                    :initform nil
                    :reader esi-read-timeout-seconds))
  (:default-initargs :message "Read timed out")
  (:report (lambda (condition stream)
             (format stream "ESI Read Timeout~@[ (~A)~]~@[: ~A seconds~]"
                     (esi-error-endpoint condition)
                     (esi-read-timeout-seconds condition)))))

;;; ---------------------------------------------------------------------------
;;; Status code to condition mapping
;;; ---------------------------------------------------------------------------

(defparameter *status-code-condition-map*
  '((400 . esi-bad-request)
    (401 . esi-unauthorized)
    (403 . esi-forbidden)
    (404 . esi-not-found)
    (420 . esi-rate-limit-exceeded)
    (422 . esi-unprocessable-entity)
    (500 . esi-internal-error)
    (502 . esi-bad-gateway)
    (503 . esi-service-unavailable)
    (504 . esi-gateway-timeout))
  "Mapping from HTTP status codes to ESI condition types.")

(defun status-code->condition-type (status-code)
  "Return the ESI condition type for a given HTTP status code.
Returns the specific condition type if mapped, or a generic client/server error
condition based on the status code range, or ESI-ERROR as fallback.

STATUS-CODE: HTTP status code integer

Example:
  (status-code->condition-type 404) => ESI-NOT-FOUND
  (status-code->condition-type 418) => ESI-CLIENT-ERROR"
  (or (cdr (assoc status-code *status-code-condition-map*))
      (cond
        ((<= 400 status-code 499) 'esi-client-error)
        ((<= 500 status-code 599) 'esi-server-error)
        (t 'esi-error))))

(defun signal-esi-error (status-code &key message endpoint response-body response-headers)
  "Signal an appropriate ESI error condition for the given STATUS-CODE.
Establishes USE-VALUE and RETRY restarts for error recovery.

STATUS-CODE: HTTP status code integer
MESSAGE: Human-readable error description
ENDPOINT: The ESI endpoint path
RESPONSE-BODY: Raw response body from the server
RESPONSE-HEADERS: Response headers hash-table

Restarts:
  USE-VALUE: Supply a substitute return value
  RETRY: Retry the failed operation"
  (let ((condition-type (status-code->condition-type status-code)))
    (restart-case
        (error condition-type
               :status-code status-code
               :message (or message (format nil "HTTP ~D" status-code))
               :endpoint endpoint
               :response-body response-body
               :response-headers response-headers)
      (use-value (value)
        :report "Supply a value to use instead of the failed request."
        :interactive (lambda ()
                       (format t "Enter a value: ")
                       (list (eval (read))))
        value)
      (retry ()
        :report "Retry the failed ESI request."
        nil))))

;;; ---------------------------------------------------------------------------
;;; Predicate utilities  
;;; ---------------------------------------------------------------------------

(defun retryable-status-p (status-code)
  "Return T if the HTTP status code indicates a retryable error.
Retryable errors are transient: rate limits, server errors, and gateway issues.

STATUS-CODE: HTTP status code integer

Example:
  (retryable-status-p 420) => T
  (retryable-status-p 404) => NIL"
  (member status-code '(420 500 502 503 504) :test #'=))

(defun rate-limited-p (status-code)
  "Return T if the HTTP status code indicates rate limiting.

STATUS-CODE: HTTP status code integer"
  (= status-code 420))
