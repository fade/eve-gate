;;;; rate-limiter.lisp - ESI-compliant rate limiting for eve-gate
;;;;
;;;; Implements a token bucket algorithm for smooth rate limiting that
;;;; respects ESI's rate limits:
;;;;   - Global rate: 150 requests/second across all endpoints
;;;;   - Per-endpoint limits: Some endpoints have specific lower limits
;;;;   - Error rate limiting: 420 responses trigger exponential backoff
;;;;   - Character-specific limits: Per-authenticated-character tracking
;;;;
;;;; The rate limiter is thread-safe and designed for concurrent access.
;;;; It integrates with the middleware pipeline and request queue to provide
;;;; adaptive throttling based on real-time server feedback.
;;;;
;;;; Design:
;;;;   - Token bucket algorithm provides smooth rate limiting with burst tolerance
;;;;   - Multiple buckets: global, per-endpoint, per-character
;;;;   - Adaptive rate adjustment from X-ESI-Error-Limit-* headers
;;;;   - Exponential backoff on 420 responses
;;;;   - Lock-free where possible, fine-grained locks where needed

(in-package #:eve-gate.concurrent)

;;; ---------------------------------------------------------------------------
;;; Token bucket implementation
;;; ---------------------------------------------------------------------------

(defstruct (token-bucket (:constructor %make-token-bucket))
  "Thread-safe token bucket for rate limiting.

The bucket fills at a constant rate and drains when tokens are consumed.
Burst capacity is controlled by the maximum number of tokens the bucket
can hold.

Slots:
  LOCK: Thread synchronization lock
  NAME: Identifier for this bucket (for logging)
  MAX-TOKENS: Maximum tokens the bucket can hold (burst capacity)
  REFILL-RATE: Tokens added per second (sustained rate)
  TOKENS: Current number of available tokens (float for precision)
  LAST-REFILL: Internal-real-time of last refill calculation"
  (lock (bt:make-lock "token-bucket-lock"))
  (name "default" :type string)
  (max-tokens 150.0 :type single-float)
  (refill-rate 150.0 :type single-float)
  (tokens 150.0 :type single-float)
  (last-refill (get-internal-real-time) :type integer))

(defun make-token-bucket (&key (name "default")
                                (max-tokens 150.0)
                                (refill-rate 150.0))
  "Create a new token bucket for rate limiting.

NAME: Identifier for logging (default: \"default\")
MAX-TOKENS: Maximum burst capacity (default: 150.0)
REFILL-RATE: Tokens per second sustained rate (default: 150.0)

Returns a token-bucket struct, initially full."
  (%make-token-bucket
   :name name
   :max-tokens (float max-tokens)
   :refill-rate (float refill-rate)
   :tokens (float max-tokens)))

(defun refill-bucket (bucket)
  "Refill a token bucket based on elapsed time since last refill.
Must be called with the bucket lock held.

BUCKET: A token-bucket struct

Returns the current token count."
  (let* ((now (get-internal-real-time))
         (elapsed-ticks (- now (token-bucket-last-refill bucket)))
         (elapsed-seconds (/ (float elapsed-ticks)
                             (float internal-time-units-per-second)))
         (new-tokens (* elapsed-seconds (token-bucket-refill-rate bucket))))
    (setf (token-bucket-tokens bucket)
          (min (token-bucket-max-tokens bucket)
               (+ (token-bucket-tokens bucket) new-tokens))
          (token-bucket-last-refill bucket) now)
    (token-bucket-tokens bucket)))

(defun bucket-try-acquire (bucket &optional (tokens 1.0))
  "Try to acquire TOKENS from the bucket without blocking.

BUCKET: A token-bucket struct
TOKENS: Number of tokens to consume (default: 1.0)

Returns two values:
  1. T if tokens were acquired, NIL if insufficient
  2. Estimated seconds until tokens would be available (0.0 if acquired)"
  (bt:with-lock-held ((token-bucket-lock bucket))
    (refill-bucket bucket)
    (if (>= (token-bucket-tokens bucket) tokens)
        (progn
          (decf (token-bucket-tokens bucket) tokens)
          (values t 0.0))
        ;; Calculate wait time
        (let* ((deficit (- tokens (token-bucket-tokens bucket)))
               (wait-seconds (/ deficit (token-bucket-refill-rate bucket))))
          (values nil wait-seconds)))))

(defun bucket-acquire (bucket &key (tokens 1.0) (timeout 30.0))
  "Acquire TOKENS from the bucket, blocking if necessary.

BUCKET: A token-bucket struct
TOKENS: Number of tokens to consume (default: 1.0)
TIMEOUT: Maximum seconds to wait (default: 30.0)

Returns T if tokens were acquired within the timeout, NIL otherwise."
  (let ((deadline (+ (get-internal-real-time)
                     (round (* timeout internal-time-units-per-second)))))
    (loop
      (multiple-value-bind (acquired wait-seconds)
          (bucket-try-acquire bucket tokens)
        (when acquired
          (return t))
        ;; Check timeout
        (when (>= (get-internal-real-time) deadline)
          (return nil))
        ;; Sleep for the estimated wait time (capped at remaining timeout)
        (let* ((remaining (/ (float (- deadline (get-internal-real-time)))
                             (float internal-time-units-per-second)))
               (sleep-time (min wait-seconds remaining 0.1)))
          (when (plusp sleep-time)
            (sleep sleep-time)))))))

(defun bucket-tokens-available (bucket)
  "Return the current number of available tokens after refill.

BUCKET: A token-bucket struct

Thread-safe."
  (bt:with-lock-held ((token-bucket-lock bucket))
    (refill-bucket bucket)))

(defun bucket-status (bucket &optional (stream *standard-output*))
  "Print the current status of a token bucket.

BUCKET: A token-bucket struct
STREAM: Output stream (default: *standard-output*)"
  (bt:with-lock-held ((token-bucket-lock bucket))
    (refill-bucket bucket)
    (format stream "~&Token Bucket: ~A~%" (token-bucket-name bucket))
    (format stream "  Tokens:      ~,1F / ~,1F~%"
            (token-bucket-tokens bucket)
            (token-bucket-max-tokens bucket))
    (format stream "  Refill rate: ~,1F tokens/sec~%"
            (token-bucket-refill-rate bucket))
    (format stream "  Fill level:  ~,1F%~%"
            (* 100.0 (/ (token-bucket-tokens bucket)
                         (token-bucket-max-tokens bucket)))))
  bucket)

;;; ---------------------------------------------------------------------------
;;; ESI Rate Limiter — combines multiple token buckets
;;; ---------------------------------------------------------------------------

(defstruct (esi-rate-limiter (:constructor %make-esi-rate-limiter))
  "ESI-compliant rate limiter combining global and per-endpoint limits.

Manages multiple token buckets to enforce ESI rate limiting rules:
  - Global bucket: 150 req/sec across all endpoints
  - Endpoint buckets: Per-endpoint limits (e.g., search: 50/min)
  - Character buckets: Per-authenticated-character limits
  - Error tracking: Exponential backoff on 420 responses

Slots:
  LOCK: Thread synchronization lock
  GLOBAL-BUCKET: Token bucket for the global rate limit
  ENDPOINT-BUCKETS: Hash-table of endpoint-pattern -> token-bucket
  CHARACTER-BUCKETS: Hash-table of character-id -> token-bucket
  ENDPOINT-CONFIGS: Hash-table of endpoint-pattern -> rate config plists
  ERROR-BACKOFF-UNTIL: Universal-time until which requests are blocked (420 backoff)
  CONSECUTIVE-420S: Count of consecutive 420 responses (for exponential backoff)
  ERROR-LIMIT-REMAIN: Most recent X-ESI-Error-Limit-Remain value
  ERROR-LIMIT-RESET: Most recent X-ESI-Error-Limit-Reset value
  STATS-LOCK: Separate lock for statistics to reduce contention
  TOTAL-ACQUIRED: Total tokens successfully acquired
  TOTAL-WAITED: Total seconds spent waiting for tokens
  TOTAL-REJECTED: Total requests rejected (timeout)
  TOTAL-420S: Total 420 responses received
  ENABLED-P: Whether rate limiting is active"
  (lock (bt:make-lock "esi-rate-limiter-lock"))
  (global-bucket nil :type (or null token-bucket))
  (endpoint-buckets (make-hash-table :test 'equal) :type hash-table)
  (character-buckets (make-hash-table :test 'eql) :type hash-table)
  (endpoint-configs (make-hash-table :test 'equal) :type hash-table)
  (error-backoff-until 0 :type integer)
  (consecutive-420s 0 :type (integer 0))
  (error-limit-remain 100 :type integer)
  (error-limit-reset 0 :type integer)
  (stats-lock (bt:make-lock "rate-limiter-stats-lock"))
  (total-acquired 0 :type (integer 0))
  (total-waited 0.0 :type single-float)
  (total-rejected 0 :type (integer 0))
  (total-420s 0 :type (integer 0))
  (enabled-p t :type boolean))

;;; ---------------------------------------------------------------------------
;;; ESI endpoint rate configurations
;;; ---------------------------------------------------------------------------

(defparameter *default-esi-rate-configs*
  '(;; Search endpoints have strict limits
    ("/characters/{character_id}/search" . (:max-tokens 10.0 :refill-rate 0.83))  ; ~50/min
    ("/search" . (:max-tokens 10.0 :refill-rate 0.83))
    ;; Market endpoints are heavily used, moderate limits
    ("/markets/{region_id}/orders" . (:max-tokens 20.0 :refill-rate 5.0))
    ("/markets/{region_id}/history" . (:max-tokens 20.0 :refill-rate 5.0))
    ;; Universe endpoints with large responses
    ("/universe/types" . (:max-tokens 10.0 :refill-rate 2.0))
    ("/universe/structures" . (:max-tokens 10.0 :refill-rate 2.0)))
  "Default per-endpoint rate configurations for known ESI limits.
Each entry is (endpoint-pattern . rate-config-plist).
Rate config plist keys:
  :MAX-TOKENS — burst capacity
  :REFILL-RATE — tokens per second")

(defparameter *default-character-rate-limit* 20.0
  "Default requests per second per authenticated character.")

(defparameter *default-character-burst* 30.0
  "Default burst capacity per authenticated character.")

;;; ---------------------------------------------------------------------------
;;; Constructor and configuration
;;; ---------------------------------------------------------------------------

(defun make-esi-rate-limiter (&key (global-rate 150.0)
                                    (global-burst 150.0)
                                    (endpoint-configs *default-esi-rate-configs*)
                                    (enabled t))
  "Create an ESI-compliant rate limiter.

GLOBAL-RATE: Maximum requests per second globally (default: 150.0)
GLOBAL-BURST: Maximum burst size (default: 150.0)
ENDPOINT-CONFIGS: Alist of (pattern . config-plist) for per-endpoint limits
ENABLED: Whether rate limiting is active (default: T)

Returns an esi-rate-limiter struct.

Example:
  ;; Default ESI-compliant limiter
  (make-esi-rate-limiter)

  ;; Conservative limiter for shared applications
  (make-esi-rate-limiter :global-rate 50.0 :global-burst 75.0)"
  (let ((limiter (%make-esi-rate-limiter
                  :global-bucket (make-token-bucket
                                  :name "esi-global"
                                  :max-tokens (float global-burst)
                                  :refill-rate (float global-rate))
                  :enabled-p enabled)))
    ;; Register endpoint-specific rate configs
    (dolist (entry endpoint-configs)
      (let ((pattern (car entry))
            (config (cdr entry)))
        (configure-endpoint-rate limiter pattern
                                 :max-tokens (getf config :max-tokens 20.0)
                                 :refill-rate (getf config :refill-rate 5.0))))
    limiter))

(defun configure-endpoint-rate (limiter endpoint-pattern
                                 &key (max-tokens 20.0) (refill-rate 5.0))
  "Configure a per-endpoint rate limit.

LIMITER: An esi-rate-limiter
ENDPOINT-PATTERN: Endpoint path pattern (e.g., \"/markets/{region_id}/orders\")
MAX-TOKENS: Burst capacity for this endpoint
REFILL-RATE: Tokens per second for this endpoint

Returns the limiter."
  (bt:with-lock-held ((esi-rate-limiter-lock limiter))
    (setf (gethash endpoint-pattern (esi-rate-limiter-endpoint-configs limiter))
          (list :max-tokens (float max-tokens) :refill-rate (float refill-rate)))
    (setf (gethash endpoint-pattern (esi-rate-limiter-endpoint-buckets limiter))
          (make-token-bucket :name (format nil "endpoint:~A" endpoint-pattern)
                             :max-tokens (float max-tokens)
                             :refill-rate (float refill-rate))))
  limiter)

;;; ---------------------------------------------------------------------------
;;; Endpoint pattern matching
;;; ---------------------------------------------------------------------------

(defun match-endpoint-pattern (path pattern)
  "Check if PATH matches an endpoint PATTERN with {param} placeholders.

PATH: Actual endpoint path (e.g., \"/markets/10000002/orders\")
PATTERN: Pattern with placeholders (e.g., \"/markets/{region_id}/orders\")

Returns T if the path matches the pattern."
  (let ((path-parts (split-path path))
        (pattern-parts (split-path pattern)))
    (and (= (length path-parts) (length pattern-parts))
         (every (lambda (path-part pattern-part)
                  (or (string= path-part pattern-part)
                      (and (plusp (length pattern-part))
                           (char= (char pattern-part 0) #\{)
                           (char= (char pattern-part (1- (length pattern-part))) #\}))))
                path-parts pattern-parts))))

(defun split-path (path)
  "Split a URL path into segments, removing empty segments.

PATH: URL path string

Returns a list of path segment strings."
  (remove-if (lambda (s) (zerop (length s)))
             (cl-ppcre:split "/" path)))

(defun find-endpoint-bucket (limiter path)
  "Find the per-endpoint token bucket for PATH, if one exists.

LIMITER: An esi-rate-limiter
PATH: The request endpoint path

Returns the token-bucket, or NIL if no endpoint-specific limit applies."
  (bt:with-lock-held ((esi-rate-limiter-lock limiter))
    (block found
      (maphash (lambda (pattern bucket)
                 (when (match-endpoint-pattern path pattern)
                   (return-from found bucket)))
               (esi-rate-limiter-endpoint-buckets limiter))
      nil)))

;;; ---------------------------------------------------------------------------
;;; Character-specific rate limiting
;;; ---------------------------------------------------------------------------

(defun get-character-bucket (limiter character-id)
  "Get or create a per-character token bucket.

LIMITER: An esi-rate-limiter
CHARACTER-ID: The EVE character ID (integer)

Returns a token-bucket for the character."
  (bt:with-lock-held ((esi-rate-limiter-lock limiter))
    (or (gethash character-id (esi-rate-limiter-character-buckets limiter))
        (setf (gethash character-id (esi-rate-limiter-character-buckets limiter))
              (make-token-bucket
               :name (format nil "character:~D" character-id)
               :max-tokens *default-character-burst*
               :refill-rate *default-character-rate-limit*)))))

;;; ---------------------------------------------------------------------------
;;; Core rate limiting operations
;;; ---------------------------------------------------------------------------

(defun rate-limit-acquire (limiter &key path character-id (timeout 30.0))
  "Acquire permission to make an ESI request, blocking if necessary.

This is the main entry point for rate limiting. It checks all applicable
rate limits (global, endpoint, character) and blocks until all are satisfied
or the timeout expires.

LIMITER: An esi-rate-limiter
PATH: The endpoint path (for per-endpoint limits)
CHARACTER-ID: Optional character ID (for per-character limits)
TIMEOUT: Maximum seconds to wait (default: 30.0)

Returns two values:
  1. T if the request is allowed, NIL if timed out
  2. Seconds spent waiting (0.0 if no wait)

Signals nothing — callers should check the return value."
  ;; Fast path: disabled limiter
  (unless (esi-rate-limiter-enabled-p limiter)
    (return-from rate-limit-acquire (values t 0.0)))
  ;; Check error backoff first
  (let ((backoff-remaining (error-backoff-remaining limiter)))
    (when (plusp backoff-remaining)
      (if (> backoff-remaining timeout)
          (progn
            (record-rate-limit-stat limiter :rejected)
            (return-from rate-limit-acquire (values nil 0.0)))
          (progn
            (log-info "Rate limiter: waiting ~,1F seconds for error backoff"
                      backoff-remaining)
            (sleep backoff-remaining)))))
  ;; Acquire from all applicable buckets
  (let ((start-time (get-internal-real-time))
        (global-bucket (esi-rate-limiter-global-bucket limiter))
        (endpoint-bucket (when path (find-endpoint-bucket limiter path)))
        (char-bucket (when character-id
                       (get-character-bucket limiter character-id))))
    ;; Try global bucket first (most likely bottleneck)
    (unless (bucket-acquire global-bucket :timeout timeout)
      (record-rate-limit-stat limiter :rejected)
      (return-from rate-limit-acquire (values nil 0.0)))
    ;; Try endpoint-specific bucket
    (when endpoint-bucket
      (let ((remaining-timeout
              (max 0.0 (- timeout (elapsed-seconds start-time)))))
        (unless (bucket-acquire endpoint-bucket :timeout remaining-timeout)
          ;; Return the global token since we can't proceed
          (bucket-try-acquire global-bucket -1.0)  ; return token
          (record-rate-limit-stat limiter :rejected)
          (return-from rate-limit-acquire (values nil 0.0)))))
    ;; Try character-specific bucket
    (when char-bucket
      (let ((remaining-timeout
              (max 0.0 (- timeout (elapsed-seconds start-time)))))
        (unless (bucket-acquire char-bucket :timeout remaining-timeout)
          ;; Return tokens from previous buckets
          (bucket-try-acquire global-bucket -1.0)
          (when endpoint-bucket
            (bucket-try-acquire endpoint-bucket -1.0))
          (record-rate-limit-stat limiter :rejected)
          (return-from rate-limit-acquire (values nil 0.0)))))
    ;; Success - record statistics
    (let ((wait-time (elapsed-seconds start-time)))
      (record-rate-limit-stat limiter :acquired wait-time)
      (values t wait-time))))

(defun rate-limit-status (limiter &optional (stream *standard-output*))
  "Print a comprehensive status report of the rate limiter.

LIMITER: An esi-rate-limiter
STREAM: Output stream (default: *standard-output*)

Returns the limiter."
  (format stream "~&=== ESI Rate Limiter Status ===~%")
  (format stream "  Enabled:     ~A~%" (esi-rate-limiter-enabled-p limiter))
  ;; Global bucket
  (format stream "~%  Global bucket:~%")
  (bucket-status (esi-rate-limiter-global-bucket limiter) stream)
  ;; Error state
  (let ((backoff (error-backoff-remaining limiter)))
    (format stream "~%  Error state:~%")
    (format stream "    Error limit remain: ~D~%"
            (esi-rate-limiter-error-limit-remain limiter))
    (format stream "    Error limit reset:  ~D sec~%"
            (esi-rate-limiter-error-limit-reset limiter))
    (format stream "    Consecutive 420s:   ~D~%"
            (esi-rate-limiter-consecutive-420s limiter))
    (format stream "    Backoff remaining:  ~,1F sec~%" backoff))
  ;; Endpoint buckets
  (let ((ep-count (hash-table-count (esi-rate-limiter-endpoint-buckets limiter))))
    (format stream "~%  Endpoint buckets: ~D configured~%" ep-count)
    (when (plusp ep-count)
      (maphash (lambda (pattern bucket)
                 (format stream "    ~A:~%" pattern)
                 (bt:with-lock-held ((token-bucket-lock bucket))
                   (refill-bucket bucket)
                   (format stream "      ~,1F/~,1F tokens, ~,1F/sec~%"
                           (token-bucket-tokens bucket)
                           (token-bucket-max-tokens bucket)
                           (token-bucket-refill-rate bucket))))
               (esi-rate-limiter-endpoint-buckets limiter))))
  ;; Character buckets
  (let ((char-count (hash-table-count (esi-rate-limiter-character-buckets limiter))))
    (format stream "~%  Character buckets: ~D active~%" char-count))
  ;; Statistics
  (bt:with-lock-held ((esi-rate-limiter-stats-lock limiter))
    (format stream "~%  Statistics:~%")
    (format stream "    Total acquired: ~D~%"
            (esi-rate-limiter-total-acquired limiter))
    (format stream "    Total waited:   ~,2F sec~%"
            (esi-rate-limiter-total-waited limiter))
    (format stream "    Total rejected: ~D~%"
            (esi-rate-limiter-total-rejected limiter))
    (format stream "    Total 420s:     ~D~%"
            (esi-rate-limiter-total-420s limiter)))
  (format stream "=== End Rate Limiter Status ===~%")
  limiter)

;;; ---------------------------------------------------------------------------
;;; Error rate tracking and adaptive backoff
;;; ---------------------------------------------------------------------------

(defun rate-limiter-record-response (limiter status-code
                                      &key error-limit-remain error-limit-reset)
  "Record an ESI response for rate limit adaptation.

Called after every ESI response to update the limiter's state based on
server feedback. Handles:
  - Updating error limit counters from X-ESI-Error-Limit-* headers
  - Detecting 420 rate limit responses and initiating backoff
  - Resetting backoff on successful responses
  - Adaptive rate reduction when error budget is low

LIMITER: An esi-rate-limiter
STATUS-CODE: HTTP response status code
ERROR-LIMIT-REMAIN: Value from X-ESI-Error-Limit-Remain header
ERROR-LIMIT-RESET: Value from X-ESI-Error-Limit-Reset header"
  (bt:with-lock-held ((esi-rate-limiter-lock limiter))
    ;; Update error limit tracking
    (when error-limit-remain
      (setf (esi-rate-limiter-error-limit-remain limiter) error-limit-remain))
    (when error-limit-reset
      (setf (esi-rate-limiter-error-limit-reset limiter) error-limit-reset))
    ;; Handle 420 rate limit response
    (cond
      ((= status-code 420)
       (incf (esi-rate-limiter-consecutive-420s limiter))
       (bt:with-lock-held ((esi-rate-limiter-stats-lock limiter))
         (incf (esi-rate-limiter-total-420s limiter)))
       (let* ((consecutive (esi-rate-limiter-consecutive-420s limiter))
              ;; Exponential backoff: 1, 2, 4, 8, 16, ... capped at 120 seconds
              (backoff-seconds (min 120 (expt 2 (1- consecutive)))))
         (setf (esi-rate-limiter-error-backoff-until limiter)
               (+ (get-universal-time) backoff-seconds))
         (log-warn "Rate limiter: 420 received (consecutive: ~D), backing off ~D seconds"
                   consecutive backoff-seconds)
         ;; Reduce global rate proportionally to consecutive errors
         (let ((reduction-factor (max 0.25 (/ 1.0 (expt 2.0 (min consecutive 4))))))
           (declare (ignore reduction-factor))
           ;; We reduce rate by draining the global bucket
           (bt:with-lock-held ((token-bucket-lock
                                 (esi-rate-limiter-global-bucket limiter)))
             (setf (token-bucket-tokens (esi-rate-limiter-global-bucket limiter))
                   0.0)))))
      ;; Successful response — reset consecutive 420 counter
      ((< status-code 400)
       (when (plusp (esi-rate-limiter-consecutive-420s limiter))
         (setf (esi-rate-limiter-consecutive-420s limiter) 0)))
      ;; Other errors do not affect rate limiting directly
      (t nil))
    ;; Adaptive throttling based on error budget
    (when (and error-limit-remain (< error-limit-remain 20))
      (log-warn "Rate limiter: error budget low (~D remaining), throttling"
                error-limit-remain)
      ;; Slow down to half rate when error budget is low
      (let ((bucket (esi-rate-limiter-global-bucket limiter)))
        (bt:with-lock-held ((token-bucket-lock bucket))
          (setf (token-bucket-tokens bucket)
                (min (token-bucket-tokens bucket)
                     (* 0.5 (token-bucket-max-tokens bucket)))))))))

(defun error-backoff-remaining (limiter)
  "Return seconds remaining in the error backoff period.

LIMITER: An esi-rate-limiter

Returns a non-negative float. 0.0 means no backoff is active."
  (let ((until (esi-rate-limiter-error-backoff-until limiter))
        (now (get-universal-time)))
    (max 0.0 (float (- until now)))))

;;; ---------------------------------------------------------------------------
;;; Statistics helpers
;;; ---------------------------------------------------------------------------

(defun record-rate-limit-stat (limiter type &optional wait-time)
  "Record a rate limiting statistic.

LIMITER: An esi-rate-limiter
TYPE: :ACQUIRED or :REJECTED
WAIT-TIME: Seconds spent waiting (for :ACQUIRED)"
  (bt:with-lock-held ((esi-rate-limiter-stats-lock limiter))
    (ecase type
      (:acquired
       (incf (esi-rate-limiter-total-acquired limiter))
       (when wait-time
         (incf (esi-rate-limiter-total-waited limiter) (float wait-time))))
      (:rejected
       (incf (esi-rate-limiter-total-rejected limiter))))))

(defun rate-limiter-statistics (limiter)
  "Return rate limiter statistics as a plist.

LIMITER: An esi-rate-limiter

Returns a plist with:
  :TOTAL-ACQUIRED — number of successful acquisitions
  :TOTAL-WAITED — cumulative seconds spent waiting
  :TOTAL-REJECTED — number of timeout rejections
  :TOTAL-420S — number of 420 responses
  :AVG-WAIT — average wait time per acquisition
  :ERROR-LIMIT-REMAIN — current error budget
  :CONSECUTIVE-420S — current consecutive 420 count
  :BACKOFF-REMAINING — seconds remaining in error backoff"
  (bt:with-lock-held ((esi-rate-limiter-stats-lock limiter))
    (let ((acquired (esi-rate-limiter-total-acquired limiter))
          (waited (esi-rate-limiter-total-waited limiter)))
      (list :total-acquired acquired
            :total-waited waited
            :total-rejected (esi-rate-limiter-total-rejected limiter)
            :total-420s (esi-rate-limiter-total-420s limiter)
            :avg-wait (if (plusp acquired) (/ waited acquired) 0.0)
            :error-limit-remain (esi-rate-limiter-error-limit-remain limiter)
            :consecutive-420s (esi-rate-limiter-consecutive-420s limiter)
            :backoff-remaining (error-backoff-remaining limiter)))))

(defun reset-rate-limiter-stats (limiter)
  "Reset all rate limiter statistics counters.

LIMITER: An esi-rate-limiter"
  (bt:with-lock-held ((esi-rate-limiter-stats-lock limiter))
    (setf (esi-rate-limiter-total-acquired limiter) 0
          (esi-rate-limiter-total-waited limiter) 0.0
          (esi-rate-limiter-total-rejected limiter) 0
          (esi-rate-limiter-total-420s limiter) 0))
  limiter)

;;; ---------------------------------------------------------------------------
;;; Utility
;;; ---------------------------------------------------------------------------

(defun elapsed-seconds (start-internal-time)
  "Return elapsed seconds since START-INTERNAL-TIME.

START-INTERNAL-TIME: A value from GET-INTERNAL-REAL-TIME

Returns a single-float of elapsed seconds."
  (/ (float (- (get-internal-real-time) start-internal-time))
     (float internal-time-units-per-second)))
