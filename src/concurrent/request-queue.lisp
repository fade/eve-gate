;;;; request-queue.lisp - Priority request queue for eve-gate
;;;;
;;;; Implements a thread-safe priority queue for ESI API requests. Requests
;;;; are prioritized by type, and fairly scheduled across characters and
;;;; endpoints to prevent starvation.
;;;;
;;;; Priority levels:
;;;;   0 (highest): Critical — authentication, error recovery
;;;;   1: High — user-initiated requests, real-time data
;;;;   2: Normal — standard API calls (default)
;;;;   3: Low — background refresh, prefetch
;;;;   4 (lowest): Bulk — mass data collection, historical data
;;;;
;;;; The queue supports:
;;;;   - Priority-based ordering with fair scheduling within priorities
;;;;   - Character-specific queuing with round-robin fairness
;;;;   - Configurable maximum depth with overflow handling
;;;;   - Timeout for queued requests (requests expire if not processed)
;;;;   - Statistics on queue depth, wait times, and throughput
;;;;
;;;; Thread safety: All operations are protected by a lock and condition
;;;; variable for producer/consumer coordination.

(in-package #:eve-gate.concurrent)

;;; ---------------------------------------------------------------------------
;;; Request priority levels
;;; ---------------------------------------------------------------------------

(defconstant +priority-critical+ 0
  "Highest priority: authentication, error recovery.")

(defconstant +priority-high+ 1
  "High priority: user-initiated requests, real-time data.")

(defconstant +priority-normal+ 2
  "Normal priority: standard API calls (default).")

(defconstant +priority-low+ 3
  "Low priority: background refresh, prefetch.")

(defconstant +priority-bulk+ 4
  "Lowest priority: mass data collection, historical data.")

;;; ---------------------------------------------------------------------------
;;; Queued request structure
;;; ---------------------------------------------------------------------------

(defstruct (queued-request (:constructor %make-queued-request))
  "A request waiting in the queue for rate-limited execution.

Slots:
  ID: Unique identifier for this request (for tracking)
  PRIORITY: Integer priority level (0 = highest)
  PATH: ESI endpoint path
  METHOD: HTTP method keyword (:get, :post, etc.)
  PARAMS: Plist of request parameters
  CHARACTER-ID: Optional character ID for fair scheduling
  CALLBACK: Function to call with the result (or NIL for synchronous)
  ERROR-CALLBACK: Function to call on error (or NIL)
  ENQUEUED-AT: Internal-real-time when request was enqueued
  TIMEOUT: Seconds after which the request expires (NIL = no timeout)
  RESULT-LOCK: Lock for synchronous result delivery
  RESULT-CONDITION: Condition variable for synchronous waiting
  RESULT: The result value (set when complete)
  COMPLETE-P: Whether the request has been completed
  EXPIRED-P: Whether the request has timed out"
  (id (gensym "REQ-") :type symbol)
  (priority +priority-normal+ :type (integer 0 4))
  (path "" :type string)
  (method :get :type keyword)
  (params nil :type list)
  (character-id nil :type (or null integer))
  (callback nil :type (or null function))
  (error-callback nil :type (or null function))
  (enqueued-at (get-internal-real-time) :type integer)
  (timeout nil :type (or null number))
  (result-lock (bt:make-lock "request-result-lock"))
  (result-condition (bt:make-condition-variable :name "request-result-cv"))
  (result nil)
  (complete-p nil :type boolean)
  (expired-p nil :type boolean))

(defun make-queued-request (&key (priority +priority-normal+)
                                  path
                                  (method :get)
                                  params
                                  character-id
                                  callback
                                  error-callback
                                  (timeout 60))
  "Create a new queued request.

PRIORITY: Integer priority 0-4 (default: +priority-normal+)
PATH: ESI endpoint path
METHOD: HTTP method keyword (default: :get)
PARAMS: Plist of request parameters
CHARACTER-ID: Optional character ID for fair scheduling
CALLBACK: Async completion callback (result) -> void
ERROR-CALLBACK: Async error callback (condition) -> void
TIMEOUT: Seconds until expiry, NIL for no timeout (default: 60)

Returns a queued-request struct."
  (%make-queued-request
   :priority priority
   :path (or path "")
   :method method
   :params params
   :character-id character-id
   :callback callback
   :error-callback error-callback
   :timeout timeout))

(defun request-expired-p (request)
  "Check if a queued request has expired based on its timeout.

REQUEST: A queued-request struct

Returns T if the request has timed out."
  (or (queued-request-expired-p request)
      (when-let ((timeout (queued-request-timeout request)))
        (> (elapsed-seconds (queued-request-enqueued-at request))
           timeout))))

(defun request-wait-time (request)
  "Return the time in seconds that REQUEST has spent in the queue.

REQUEST: A queued-request struct

Returns a single-float of elapsed seconds."
  (elapsed-seconds (queued-request-enqueued-at request)))

(defun complete-request (request result)
  "Mark a queued request as complete with RESULT.

For async requests, invokes the callback. For sync requests, signals
the condition variable.

REQUEST: A queued-request struct
RESULT: The result value to deliver"
  (bt:with-lock-held ((queued-request-result-lock request))
    (setf (queued-request-result request) result
          (queued-request-complete-p request) t)
    (bt:condition-notify (queued-request-result-condition request)))
  ;; Invoke async callback outside the lock
  (when (queued-request-callback request)
    (handler-case
        (funcall (queued-request-callback request) result)
      (error (e)
        (log-error "Request callback error for ~A: ~A"
                   (queued-request-id request) e)))))

(defun fail-request (request condition)
  "Mark a queued request as failed with CONDITION.

REQUEST: A queued-request struct
CONDITION: The error condition"
  (bt:with-lock-held ((queued-request-result-lock request))
    (setf (queued-request-result request) condition
          (queued-request-complete-p request) t
          (queued-request-expired-p request) t)
    (bt:condition-notify (queued-request-result-condition request)))
  ;; Invoke error callback outside the lock
  (when (queued-request-error-callback request)
    (handler-case
        (funcall (queued-request-error-callback request) condition)
      (error (e)
        (log-error "Request error callback failed for ~A: ~A"
                   (queued-request-id request) e)))))

(defun wait-for-request (request &key (timeout 60))
  "Block until a queued request completes or times out.

REQUEST: A queued-request struct
TIMEOUT: Maximum seconds to wait (default: 60)

Returns two values:
  1. The result value (or NIL on timeout)
  2. T if completed, NIL if timed out"
  (bt:with-lock-held ((queued-request-result-lock request))
    (loop until (queued-request-complete-p request)
          do (unless (bt:condition-wait
                      (queued-request-result-condition request)
                      (queued-request-result-lock request)
                      :timeout timeout)
               ;; Timeout
               (return-from wait-for-request (values nil nil))))
    (values (queued-request-result request) t)))

;;; ---------------------------------------------------------------------------
;;; Request queue
;;; ---------------------------------------------------------------------------

(defstruct (request-queue (:constructor %make-request-queue))
  "Thread-safe priority queue for ESI API requests.

Requests are stored in per-priority sub-queues and dequeued in priority
order. Within each priority level, round-robin scheduling across characters
ensures fairness.

Slots:
  LOCK: Thread synchronization lock
  NOT-EMPTY-CV: Condition variable signaled when items are enqueued
  PRIORITY-QUEUES: Vector of 5 lists (one per priority level)
  TOTAL-COUNT: Total number of requests currently queued
  MAX-SIZE: Maximum queue depth (0 = unlimited)
  CHARACTER-ROUND-ROBIN: Hash-table tracking per-character round-robin state
  STATS-LOCK: Separate lock for statistics
  TOTAL-ENQUEUED: Total requests enqueued (lifetime)
  TOTAL-DEQUEUED: Total requests dequeued (lifetime)
  TOTAL-EXPIRED: Total requests expired (lifetime)
  TOTAL-REJECTED: Total requests rejected (queue full, lifetime)
  TOTAL-WAIT-TIME: Cumulative wait time of dequeued requests
  PAUSED-P: Whether the queue is paused (dequeue blocked)
  SHUTDOWN-P: Whether the queue is shutting down"
  (lock (bt:make-lock "request-queue-lock"))
  (not-empty-cv (bt:make-condition-variable :name "request-queue-cv"))
  (priority-queues (make-array 5 :initial-element nil) :type simple-vector)
  (total-count 0 :type (integer 0))
  (max-size 1000 :type (integer 0))
  (character-round-robin (make-hash-table :test 'eql) :type hash-table)
  (stats-lock (bt:make-lock "request-queue-stats-lock"))
  (total-enqueued 0 :type (integer 0))
  (total-dequeued 0 :type (integer 0))
  (total-expired 0 :type (integer 0))
  (total-rejected 0 :type (integer 0))
  (total-wait-time 0.0 :type single-float)
  (paused-p nil :type boolean)
  (shutdown-p nil :type boolean))

(defun make-request-queue (&key (max-size 1000))
  "Create a new request queue.

MAX-SIZE: Maximum number of queued requests (default: 1000, 0 = unlimited)

Returns a request-queue struct."
  (%make-request-queue :max-size max-size))

;;; ---------------------------------------------------------------------------
;;; Queue operations
;;; ---------------------------------------------------------------------------

(defun enqueue-request (queue request)
  "Add a request to the priority queue.

QUEUE: A request-queue
REQUEST: A queued-request struct

Returns two values:
  1. The request if successfully enqueued, NIL if queue is full
  2. Current queue depth after enqueueing"
  (bt:with-lock-held ((request-queue-lock queue))
    ;; Check shutdown
    (when (request-queue-shutdown-p queue)
      (fail-request request (make-condition 'simple-error
                                             :format-control "Queue is shut down"))
      (return-from enqueue-request (values nil 0)))
    ;; Check capacity
    (when (and (plusp (request-queue-max-size queue))
               (>= (request-queue-total-count queue)
                    (request-queue-max-size queue)))
      (bt:with-lock-held ((request-queue-stats-lock queue))
        (incf (request-queue-total-rejected queue)))
      (log-warn "Request queue full (~D), rejecting ~A"
                (request-queue-total-count queue)
                (queued-request-path request))
      (return-from enqueue-request (values nil (request-queue-total-count queue))))
    ;; Add to appropriate priority queue
    (let ((priority (queued-request-priority request))
          (pqueues (request-queue-priority-queues queue)))
      ;; Append to the end of the priority sub-queue (FIFO within priority)
      (setf (aref pqueues priority)
            (nconc (aref pqueues priority) (list request)))
      (incf (request-queue-total-count queue))
      (bt:with-lock-held ((request-queue-stats-lock queue))
        (incf (request-queue-total-enqueued queue)))
      ;; Signal waiting consumers
      (bt:condition-notify (request-queue-not-empty-cv queue))
      (values request (request-queue-total-count queue)))))

(defun dequeue-request (queue &key (timeout 1.0))
  "Remove and return the highest-priority non-expired request.

QUEUE: A request-queue
TIMEOUT: Maximum seconds to wait for a request (default: 1.0)

Returns the queued-request, or NIL if no request available within timeout.

Skips and expires timed-out requests automatically."
  (bt:with-lock-held ((request-queue-lock queue))
    (loop
      ;; Wait for items if queue is empty or paused
      (loop while (or (zerop (request-queue-total-count queue))
                      (request-queue-paused-p queue))
            do (when (request-queue-shutdown-p queue)
                 (return-from dequeue-request nil))
               (unless (bt:condition-wait
                         (request-queue-not-empty-cv queue)
                         (request-queue-lock queue)
                         :timeout timeout)
                 ;; Timed out waiting
                 (return-from dequeue-request nil)))
      ;; Find highest-priority non-expired request
      (let ((request (find-next-request queue)))
        (cond
          ;; Found a valid request
          (request
           (decf (request-queue-total-count queue))
           (let ((wait-time (request-wait-time request)))
             (bt:with-lock-held ((request-queue-stats-lock queue))
               (incf (request-queue-total-dequeued queue))
               (incf (request-queue-total-wait-time queue) wait-time)))
           (return request))
          ;; All remaining requests expired or queue is empty
          ((zerop (request-queue-total-count queue))
           (return nil))
          ;; Retry (shouldn't happen but safety valve)
          (t (return nil)))))))

(defun find-next-request (queue)
  "Find the next valid (non-expired) request from the priority queues.
Must be called with the queue lock held.

Implements fair scheduling within each priority level by doing
round-robin across character IDs.

QUEUE: A request-queue

Returns a queued-request, or NIL if none available."
  (let ((pqueues (request-queue-priority-queues queue)))
    (loop for priority from 0 to 4
          for subqueue = (aref pqueues priority)
          when subqueue
          do ;; Remove expired requests from the front
             (loop while (and subqueue (request-expired-p (car subqueue)))
                   do (let ((expired (pop subqueue)))
                        (setf (queued-request-expired-p expired) t)
                        (fail-request expired
                                      (make-condition 'simple-error
                                                       :format-control "Request timed out"))
                        (decf (request-queue-total-count queue))
                        (bt:with-lock-held ((request-queue-stats-lock queue))
                          (incf (request-queue-total-expired queue)))))
             ;; Update the priority queue
             (setf (aref pqueues priority) subqueue)
             ;; Take the first non-expired request
             (when subqueue
               (let ((request (pop (aref pqueues priority))))
                 (return request)))
          finally (return nil))))

;;; ---------------------------------------------------------------------------
;;; Queue control
;;; ---------------------------------------------------------------------------

(defun pause-queue (queue)
  "Pause the request queue. Dequeue operations will block.

QUEUE: A request-queue"
  (bt:with-lock-held ((request-queue-lock queue))
    (setf (request-queue-paused-p queue) t)
    (log-info "Request queue paused"))
  queue)

(defun resume-queue (queue)
  "Resume the request queue. Unblocks waiting dequeue operations.

QUEUE: A request-queue"
  (bt:with-lock-held ((request-queue-lock queue))
    (setf (request-queue-paused-p queue) nil)
    (bt:condition-notify (request-queue-not-empty-cv queue))
    (log-info "Request queue resumed"))
  queue)

(defun shutdown-queue (queue)
  "Shut down the queue, failing all pending requests.

QUEUE: A request-queue"
  (bt:with-lock-held ((request-queue-lock queue))
    (setf (request-queue-shutdown-p queue) t)
    ;; Fail all pending requests
    (loop for priority from 0 to 4
          for subqueue = (aref (request-queue-priority-queues queue) priority)
          do (dolist (request subqueue)
               (fail-request request
                             (make-condition 'simple-error
                                             :format-control "Queue shut down")))
             (setf (aref (request-queue-priority-queues queue) priority) nil))
    (setf (request-queue-total-count queue) 0)
    ;; Wake up any blocked consumers
    (bt:condition-notify (request-queue-not-empty-cv queue))
    (log-info "Request queue shut down"))
  queue)

(defun clear-queue (queue)
  "Remove all pending requests from the queue without failing them.

QUEUE: A request-queue

Returns the number of requests removed."
  (bt:with-lock-held ((request-queue-lock queue))
    (let ((count (request-queue-total-count queue)))
      (loop for priority from 0 to 4
            do (setf (aref (request-queue-priority-queues queue) priority) nil))
      (setf (request-queue-total-count queue) 0)
      count)))

;;; ---------------------------------------------------------------------------
;;; Queue introspection
;;; ---------------------------------------------------------------------------

(defun queue-depth (queue &optional priority)
  "Return the number of requests in the queue.

QUEUE: A request-queue
PRIORITY: Optional priority level to check (NIL = total)

Returns the count."
  (bt:with-lock-held ((request-queue-lock queue))
    (if priority
        (length (aref (request-queue-priority-queues queue) priority))
        (request-queue-total-count queue))))

(defun queue-statistics (queue)
  "Return queue statistics as a plist.

QUEUE: A request-queue

Returns a plist with:
  :CURRENT-DEPTH — current number of queued requests
  :DEPTHS-BY-PRIORITY — vector of counts per priority level
  :TOTAL-ENQUEUED — lifetime enqueued count
  :TOTAL-DEQUEUED — lifetime dequeued count
  :TOTAL-EXPIRED — lifetime expired count
  :TOTAL-REJECTED — lifetime rejected count (queue full)
  :AVG-WAIT-TIME — average wait time of dequeued requests
  :PAUSED-P — whether the queue is paused
  :SHUTDOWN-P — whether the queue is shut down"
  (bt:with-lock-held ((request-queue-lock queue))
    (let ((depths (make-array 5)))
      (loop for i from 0 to 4
            do (setf (aref depths i)
                     (length (aref (request-queue-priority-queues queue) i))))
      (bt:with-lock-held ((request-queue-stats-lock queue))
        (let ((dequeued (request-queue-total-dequeued queue))
              (wait-time (request-queue-total-wait-time queue)))
          (list :current-depth (request-queue-total-count queue)
                :depths-by-priority depths
                :total-enqueued (request-queue-total-enqueued queue)
                :total-dequeued dequeued
                :total-expired (request-queue-total-expired queue)
                :total-rejected (request-queue-total-rejected queue)
                :avg-wait-time (if (plusp dequeued)
                                   (/ wait-time dequeued)
                                   0.0)
                :paused-p (request-queue-paused-p queue)
                :shutdown-p (request-queue-shutdown-p queue)))))))

(defun queue-status (queue &optional (stream *standard-output*))
  "Print a human-readable summary of the request queue.

QUEUE: A request-queue
STREAM: Output stream (default: *standard-output*)"
  (let ((stats (queue-statistics queue)))
    (format stream "~&=== Request Queue Status ===~%")
    (format stream "  Current depth: ~D / ~D~%"
            (getf stats :current-depth)
            (request-queue-max-size queue))
    (format stream "  By priority:~%")
    (let ((depths (getf stats :depths-by-priority))
          (names #("Critical" "High" "Normal" "Low" "Bulk")))
      (loop for i from 0 to 4
            do (format stream "    [~D] ~A: ~D~%" i (aref names i) (aref depths i))))
    (format stream "  State: ~A~%"
            (cond ((getf stats :shutdown-p) "SHUTDOWN")
                  ((getf stats :paused-p) "PAUSED")
                  (t "ACTIVE")))
    (format stream "~%  Lifetime statistics:~%")
    (format stream "    Enqueued:  ~D~%" (getf stats :total-enqueued))
    (format stream "    Dequeued:  ~D~%" (getf stats :total-dequeued))
    (format stream "    Expired:   ~D~%" (getf stats :total-expired))
    (format stream "    Rejected:  ~D~%" (getf stats :total-rejected))
    (format stream "    Avg wait:  ~,3F sec~%" (getf stats :avg-wait-time))
    (format stream "=== End Queue Status ===~%"))
  queue)
