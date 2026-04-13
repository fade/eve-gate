;;;; rate-limiter.lisp - Core rate limiter stubs for eve-gate.core
;;;;
;;;; Provides the basic rate limiting interface promised by eve-gate.core.
;;;; The full rate limiting implementation lives in eve-gate.concurrent
;;;; (src/concurrent/rate-limiter.lisp). These stubs allow the core package
;;;; to compile independently and provide a simple interface for basic use.
;;;;
;;;; For advanced rate limiting with token buckets, per-endpoint limits,
;;;; and adaptive throttling, use the eve-gate.concurrent package directly.

(in-package #:eve-gate.core)

;;; ---------------------------------------------------------------------------
;;; Simple rate limiter for core module
;;; ---------------------------------------------------------------------------

(defstruct (rate-limiter (:constructor %make-rate-limiter))
  "Simple rate limiter for the core HTTP client.

This is a basic implementation suitable for single-threaded use.
For production concurrent usage, use the esi-rate-limiter from
eve-gate.concurrent.

Slots:
  LOCK: Thread synchronization lock
  MAX-REQUESTS: Maximum requests per window
  WINDOW-SECONDS: Time window in seconds
  REQUEST-TIMES: Ring buffer of recent request timestamps
  INDEX: Current position in the ring buffer"
  (lock (bt:make-lock "rate-limiter-lock"))
  (max-requests 150 :type (integer 1))
  (window-seconds 1 :type (integer 1))
  (request-times (make-array 150 :initial-element 0) :type simple-vector)
  (index 0 :type (integer 0)))

(defun make-rate-limiter (&key (max-requests 150) (window-seconds 1))
  "Create a simple sliding-window rate limiter.

MAX-REQUESTS: Maximum requests allowed per window (default: 150)
WINDOW-SECONDS: Window duration in seconds (default: 1)

Returns a rate-limiter struct.

For production use with concurrent requests, prefer
eve-gate.concurrent:make-esi-rate-limiter."
  (%make-rate-limiter
   :max-requests max-requests
   :window-seconds window-seconds
   :request-times (make-array max-requests :initial-element 0)))

(defun rate-limit-acquire (limiter &key path character-id (timeout 30))
  "Acquire permission to make a request, blocking if necessary.

LIMITER: A rate-limiter struct
PATH: Endpoint path (unused in simple limiter)
CHARACTER-ID: Character ID (unused in simple limiter)
TIMEOUT: Maximum seconds to wait (default: 30)

Returns T if permission was granted, NIL if timed out."
  (declare (ignore path character-id))
  (let ((deadline (+ (get-internal-real-time)
                     (round (* timeout internal-time-units-per-second)))))
    (loop
      (bt:with-lock-held ((rate-limiter-lock limiter))
        (let* ((now (get-universal-time))
               (window-start (- now (rate-limiter-window-seconds limiter)))
               (idx (rate-limiter-index limiter))
               (oldest-time (aref (rate-limiter-request-times limiter) idx)))
          ;; If the oldest request in the window has expired, we can proceed
          (when (< oldest-time window-start)
            ;; Record this request
            (setf (aref (rate-limiter-request-times limiter) idx) now
                  (rate-limiter-index limiter)
                  (mod (1+ idx) (rate-limiter-max-requests limiter)))
            (return t))))
      ;; Check timeout
      (when (>= (get-internal-real-time) deadline)
        (return nil))
      ;; Brief sleep before retry
      (sleep 0.01))))

(defun rate-limit-status (limiter &optional (stream *standard-output*))
  "Print the status of a simple rate limiter.

LIMITER: A rate-limiter struct
STREAM: Output stream (default: *standard-output*)"
  (bt:with-lock-held ((rate-limiter-lock limiter))
    (let* ((now (get-universal-time))
           (window-start (- now (rate-limiter-window-seconds limiter)))
           (active-count (count-if (lambda (t0) (>= t0 window-start))
                                    (rate-limiter-request-times limiter))))
      (format stream "~&Rate Limiter: ~D/~D requests in ~D second window~%"
              active-count
              (rate-limiter-max-requests limiter)
              (rate-limiter-window-seconds limiter))))
  limiter)
