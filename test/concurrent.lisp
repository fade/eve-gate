;;;; test/concurrent.lisp - Concurrent operations tests for eve-gate
;;;;
;;;; Tests for rate limiting, request queuing, and parallel execution

(uiop:define-package #:eve-gate/test/concurrent
  (:use #:cl)
  (:import-from #:eve-gate.concurrent
                ;; Rate limiter
                #:make-token-bucket
                #:bucket-try-acquire
                #:bucket-tokens-available
                ;; Request queue
                #:make-request-queue
                #:enqueue-request
                #:dequeue-request
                #:queue-depth
                #:queue-status
                ;; Priority levels
                #:+priority-critical+
                #:+priority-high+
                #:+priority-normal+
                #:+priority-low+
                #:+priority-bulk+
                ;; Queued request
                #:make-queued-request
                ;; --- Request scheduler ---
                #:make-request-scheduler
                #:start-scheduler
                #:stop-scheduler
                #:with-scheduler
                #:request-scheduler-rate-limiter
                #:submit-refresh
                #:submit-bootstrap
                #:cancel-refresh
                #:cancel-bootstrap
                #:scheduler-state
                #:reset-scheduler-stats
                ;; Handle introspection
                #:refresh-handle-status
                #:refresh-handle-completion
                #:refresh-completion-outcome
                #:refresh-completion-event
                #:refresh-completion-data
                ;; Bootstrap handle
                #:bootstrap-handle-total
                #:bootstrap-handle-batch-id
                #:bootstrap-handle-refresh-handles
                #:bootstrap-handle-cancelled-p
                ;; Programmer-error conditions
                #:scheduler-error
                #:scheduler-error-scheduler
                #:scheduler-error-operation-id
                #:scheduler-missing-priority
                #:scheduler-invalid-priority
                #:scheduler-invalid-priority-value
                #:scheduler-not-running
                #:scheduler-queue-full
                #:scheduler-queue-full-priority
                #:scheduler-unknown-endpoint
                ;; Completion-event conditions
                #:esi-completion-event
                #:esi-skip
                #:esi-cancelled
                #:esi-budget-exhausted
                #:esi-deadline-missed
                #:esi-failure
                #:esi-http-error
                #:esi-http-4xx-error
                #:esi-http-5xx-error
                #:esi-network-failure
                #:esi-rate-limit-exhausted)
  (:import-from #:eve-gate.cache
                #:make-cache-manager
                #:make-cache-key
                #:cache-put)
  (:local-nicknames (#:t #:parachute)))

(in-package #:eve-gate/test/concurrent)

;;; Token Bucket Rate Limiter Tests

(t:define-test token-bucket-creation
  "Test token bucket creation"
  (let ((bucket (make-token-bucket :refill-rate 10.0 :max-tokens 100.0)))
    (t:true bucket)
    (t:is = 100 (bucket-tokens-available bucket))))

(t:define-test token-bucket-acquire
  "Test token acquisition from bucket"
  (let ((bucket (make-token-bucket :refill-rate 10.0 :max-tokens 10.0)))
    ;; Should be able to acquire tokens
    (t:true (bucket-try-acquire bucket 1))
    ;; Acquire more
    (t:true (bucket-try-acquire bucket 5))
    ;; Try to acquire more than available - should fail
    (t:false (bucket-try-acquire bucket 10))))

(t:define-test token-bucket-refill
  "Test token bucket refill over time"
  (let ((bucket (make-token-bucket :refill-rate 1000.0 :max-tokens 10.0)))
    ;; Drain the bucket
    (bucket-try-acquire bucket 10)
    ;; Wait a tiny bit for refill (rate is 1000/sec)
    (sleep 0.02)
    ;; Should have some tokens now
    (let ((tokens (bucket-tokens-available bucket)))
      (t:true (> tokens 0)))))

;;; Priority Level Constants Tests

(t:define-test priority-levels-exist
  "Test that priority level constants are defined"
  (t:true (integerp +priority-critical+))
  (t:true (integerp +priority-high+))
  (t:true (integerp +priority-normal+))
  (t:true (integerp +priority-low+))
  (t:true (integerp +priority-bulk+)))

;;; Request Queue Tests

(t:define-test request-queue-creation
  "Test request queue creation"
  (let ((queue (make-request-queue :max-size 100)))
    (t:true queue)
    (t:is = 0 (queue-depth queue))))

(t:define-test request-queue-enqueue
  "Test basic enqueue operations"
  (let ((queue (make-request-queue :max-size 100)))
    ;; Create and enqueue a request
    (let ((request (make-queued-request 
                    :path "/characters/12345"
                    :method :get
                    :priority +priority-normal+)))
      (enqueue-request queue request)
      (t:true (> (queue-depth queue) 0)))))

(t:define-test queue-status-function
  "Test queue status reporting prints and returns queue"
  (let ((queue (make-request-queue :max-size 100)))
    ;; queue-status prints to stream and returns the queue
    (let ((result (with-output-to-string (s)
                    (queue-status queue s))))
      ;; Should have printed something
      (t:true (> (length result) 0))
      (t:true (search "Queue Status" result)))))

;;; Thread Safety Tests

(t:define-test token-bucket-thread-safety
  "Test token bucket thread safety under concurrent access"
  (let ((bucket (make-token-bucket :refill-rate 100.0 :max-tokens 100.0))
        (acquired-count 0)
        (lock (bt:make-lock "test-lock")))
    ;; Spawn multiple threads trying to acquire tokens
    (let ((threads 
            (loop for i from 1 to 10
                  collect (bt:make-thread 
                           (lambda ()
                             (dotimes (j 10)
                               (when (bucket-try-acquire bucket 1)
                                 (bt:with-lock-held (lock)
                                   (incf acquired-count)))))
                           :name (format nil "test-thread-~d" i)))))
      ;; Wait for all threads to complete
      (dolist (thread threads)
        (bt:join-thread thread))
      
      ;; Total acquired should be >= initial capacity (100 tokens)
      ;; Some may have refilled during execution
      (t:is >= acquired-count 100))))

;;; ---------------------------------------------------------------------------
;;; Request Scheduler Tests
;;; ---------------------------------------------------------------------------
;;;
;;; These tests exercise the request-scheduler's contract without making live
;;; ESI calls. Tests that need a closed budget gate mutate the rate-limiter's
;;; error-limit-remain slot directly; tests that observe the held-queue access
;;; it under the scheduler's internal lock.

(defun %close-budget-gate (scheduler)
  "Drop the rate-limiter's error-limit-remain to 0 so the scheduler's gate
closes on its next predicate evaluation. Internal-accessor reach is
intentional — production code never closes the gate explicitly."
  (setf (eve-gate.concurrent::esi-rate-limiter-error-limit-remain
         (request-scheduler-rate-limiter scheduler))
        0))

(defun %held-queue-size (scheduler priority-index)
  "Snapshot the length of held-queue slot PRIORITY-INDEX under the
scheduler's held-queues lock."
  (bt:with-lock-held
      ((eve-gate.concurrent::request-scheduler-held-queues-lock scheduler))
    (length (aref (eve-gate.concurrent::request-scheduler-held-queues scheduler)
                  priority-index))))

(defun %bootstrap-batches-count (scheduler)
  (bt:with-lock-held
      ((eve-gate.concurrent::request-scheduler-bootstrap-batches-lock scheduler))
    (hash-table-count
     (eve-gate.concurrent::request-scheduler-bootstrap-batches scheduler))))

(t:define-test scheduler-lifecycle
  "with-scheduler constructs, starts, and stops cleanly"
  (let ((reached-body nil)
        (was-running nil))
    (with-scheduler (s)
      (setf was-running (eve-gate.concurrent::request-scheduler-running-p s))
      (setf reached-body t))
    (t:true reached-body)
    (t:true was-running)))

(t:define-test scheduler-start-stop-idempotent
  "start-scheduler and stop-scheduler are both idempotent"
  (let ((s (make-request-scheduler)))
    (start-scheduler s)
    (start-scheduler s)
    (t:true (eve-gate.concurrent::request-scheduler-running-p s))
    (stop-scheduler s)
    (stop-scheduler s)
    (t:false (eve-gate.concurrent::request-scheduler-running-p s))))

(t:define-test submit-refresh-missing-priority-signals
  "submit-refresh without :priority signals scheduler-missing-priority"
  (with-scheduler (s)
    (handler-case
        (progn (submit-refresh s :operation-id "get_status")
               (t:fail "Expected scheduler-missing-priority"))
      (scheduler-missing-priority (c)
        (t:is equal "get_status" (scheduler-error-operation-id c))))))

(t:define-test submit-refresh-bootstrap-priority-rejected
  "submit-refresh with :priority :bootstrap signals scheduler-invalid-priority"
  (with-scheduler (s)
    (handler-case
        (progn (submit-refresh s :operation-id "get_status" :priority :bootstrap)
               (t:fail "Expected scheduler-invalid-priority"))
      (scheduler-invalid-priority (c)
        (t:is eq :bootstrap (scheduler-invalid-priority-value c))))))

(t:define-test submit-refresh-unknown-endpoint-signals
  "submit-refresh with an unknown operation-id signals scheduler-unknown-endpoint"
  (with-scheduler (s)
    (handler-case
        (progn (submit-refresh s :operation-id "no_such_endpoint" :priority :warm)
               (t:fail "Expected scheduler-unknown-endpoint"))
      (scheduler-unknown-endpoint (c)
        (t:is equal "no_such_endpoint" (scheduler-error-operation-id c))))))

(t:define-test submit-refresh-cache-hit-short-circuits
  "A cache-fresh entry delivers a :cache-hit completion synchronously"
  (let* ((cm (make-cache-manager))
         (key (make-cache-key "/status/" :datasource "tranquility"))
         (received nil))
    (cache-put cm key '(:players 42 :server-version "v1")
               :operation-id "get_status")
    (with-scheduler (s :cache-manager cm)
      (submit-refresh s
                      :operation-id "get_status"
                      :priority :warm
                      :on-complete (lambda (c) (setf received c))))
    (t:true received)
    (t:is eq :cache-hit (refresh-completion-outcome received))
    (t:is equal '(:players 42 :server-version "v1")
          (refresh-completion-data received))))

(t:define-test submit-refresh-budget-closed-holds
  "A closed budget gate parks a :warm submission in held-queue slot 2"
  (with-scheduler (s :budget-threshold 50 :budget-resume 100)
    (%close-budget-gate s)
    (let ((handle (submit-refresh s
                                  :operation-id "get_status"
                                  :priority :warm
                                  :deadline-seconds 600)))
      (t:is eq :pending (refresh-handle-status handle))
      (t:is = 1 (%held-queue-size s +priority-normal+))
      (cancel-refresh s handle))))

(t:define-test submit-refresh-deadline-expired-skip
  "A held submission past its deadline delivers esi-budget-exhausted skip"
  (let ((received nil)
        (lock (bt:make-lock "deadline-skip-lock"))
        (cv (bt:make-condition-variable :name "deadline-skip-cv")))
    (with-scheduler (s :budget-threshold 50 :budget-resume 100
                       :dispatcher-poll-interval 0.05)
      (%close-budget-gate s)
      (submit-refresh s
                      :operation-id "get_status"
                      :priority :warm
                      :deadline-seconds 1
                      :on-skip (lambda (c)
                                 (bt:with-lock-held (lock)
                                   (setf received c)
                                   (bt:condition-notify cv))))
      (bt:with-lock-held (lock)
        (loop while (null received)
              do (bt:condition-wait cv lock :timeout 3))))
    (t:true received)
    (t:is eq :skipped (refresh-completion-outcome received))
    (t:true (typep (refresh-completion-event received) 'esi-budget-exhausted))
    (t:true (typep (refresh-completion-event received) 'esi-skip))))

(t:define-test gate-open-for-priority-critical-bypasses
  "Closed gate still admits :critical priority"
  (with-scheduler (s :budget-threshold 50 :budget-resume 100)
    (%close-budget-gate s)
    (eve-gate.concurrent::update-gate-state s)
    (t:false
     (eve-gate.concurrent::gate-open-for-priority-p s :warm))
    (t:true
     (eve-gate.concurrent::gate-open-for-priority-p s :critical))))

(t:define-test cancel-refresh-pending-delivers-cancelled
  "cancel-refresh on a :pending handle delivers an esi-cancelled skip"
  (let ((received nil))
    (with-scheduler (s :budget-threshold 50 :budget-resume 100)
      (%close-budget-gate s)
      (let ((handle (submit-refresh s
                                    :operation-id "get_status"
                                    :priority :warm
                                    :deadline-seconds 600
                                    :on-skip (lambda (c) (setf received c)))))
        (t:is eq :pending (refresh-handle-status handle))
        (t:true (cancel-refresh s handle))
        (t:is eq :cancelled (refresh-handle-status handle))
        ;; Double-cancel is a no-op.
        (t:false (cancel-refresh s handle))))
    (t:true received)
    (t:is eq :skipped (refresh-completion-outcome received))
    (t:true (typep (refresh-completion-event received) 'esi-cancelled))))

(t:define-test submit-bootstrap-registers-batch
  "submit-bootstrap fills slot 4 and registers the batch in bootstrap-batches"
  (with-scheduler (s :budget-threshold 50 :budget-resume 100)
    (%close-budget-gate s)
    (let ((b (submit-bootstrap s
                               (loop repeat 5
                                     collect '(:operation-id "get_status"))
                               :batch-id "test-batch")))
      (t:is = 5 (bootstrap-handle-total b))
      (t:is equal "test-batch" (bootstrap-handle-batch-id b))
      (t:is = 5 (length (bootstrap-handle-refresh-handles b)))
      (t:is = 5 (%held-queue-size s +priority-bulk+))
      (t:is = 1 (%bootstrap-batches-count s))
      (cancel-bootstrap s b))))

(t:define-test submit-bootstrap-queue-full-signals
  "Bootstrap submissions past the queue-depth cap signal scheduler-queue-full"
  (with-scheduler (s :bootstrap-queue-depth 3)
    (%close-budget-gate s)
    (handler-case
        (progn (submit-bootstrap
                s
                (loop repeat 5 collect '(:operation-id "get_status")))
               (t:fail "Expected scheduler-queue-full"))
      (scheduler-queue-full (c)
        (t:is eq :bootstrap (scheduler-queue-full-priority c))))))

(t:define-test cancel-bootstrap-counts-pending
  "cancel-bootstrap returns the count of refresh-handles actually cancelled"
  (with-scheduler (s :budget-threshold 50 :budget-resume 100)
    (%close-budget-gate s)
    (let* ((b (submit-bootstrap
               s
               (loop repeat 7 collect '(:operation-id "get_status"))))
           (cancelled-count (cancel-bootstrap s b)))
      (t:is = 7 cancelled-count)
      (t:true (bootstrap-handle-cancelled-p b))
      (t:is = 0 (%bootstrap-batches-count s)))))

(t:define-test scheduler-state-plist-shape
  "scheduler-state returns a plist with the documented keys"
  (with-scheduler (s)
    (let* ((st (scheduler-state s))
           (budget (getf st :budget))
           (queue (getf st :queue))
           (engine (getf st :engine))
           (sched (getf st :scheduler)))
      (t:true (consp budget))
      (t:true (consp queue))
      (t:true (consp engine))
      (t:true (consp sched))
      (loop for k in '(:limit-remain :limit-reset-seconds :backoff-remaining
                       :consecutive-420s :in-flight :predicted-remain)
            do (t:true (member k budget)
                       (format nil ":budget missing ~A" k)))
      (loop for k in '(:current-depth :depths-by-priority :total-enqueued
                       :total-dequeued :total-expired :total-rejected
                       :avg-wait-time)
            do (t:true (member k queue)
                       (format nil ":queue missing ~A" k)))
      (loop for k in '(:total-requests :success-rate :avg-latency :throughput
                       :worker-count)
            do (t:true (member k engine)
                       (format nil ":engine missing ~A" k)))
      (loop for k in '(:total-submitted :total-cache-hits :total-dispatched
                       :total-skipped :total-failed :skip-reasons)
            do (t:true (member k sched)
                       (format nil ":scheduler missing ~A" k)))
      ;; Without a cache-manager or active bootstrap, those blocks are NIL.
      (t:false (getf st :cache))
      (t:false (getf st :bootstrap))
      ;; Recent-failures is a list (possibly empty).
      (t:true (listp (getf st :recent-failures))))))

(t:define-test reset-scheduler-stats-zeros-counters
  "reset-scheduler-stats zeros cumulative counters without touching live state"
  (with-scheduler (s :budget-threshold 50 :budget-resume 100)
    (%close-budget-gate s)
    (let ((handle (submit-refresh s
                                  :operation-id "get_status"
                                  :priority :warm
                                  :deadline-seconds 600)))
      (cancel-refresh s handle))
    (let ((before (getf (scheduler-state s) :scheduler)))
      (t:is = 1 (getf before :total-submitted))
      (t:is = 1 (getf before :total-skipped))
      (t:true (getf before :skip-reasons)))
    (reset-scheduler-stats s)
    (let ((after (getf (scheduler-state s) :scheduler)))
      (t:is = 0 (getf after :total-submitted))
      (t:is = 0 (getf after :total-skipped))
      (t:false (getf after :skip-reasons)))))

(t:define-test scheduler-condition-hierarchy
  "scheduler-error and esi-completion-event hierarchies match the locked contract"
  ;; R2 family
  (t:true (subtypep 'scheduler-missing-priority 'scheduler-error))
  (t:true (subtypep 'scheduler-invalid-priority 'scheduler-error))
  (t:true (subtypep 'scheduler-not-running 'scheduler-error))
  (t:true (subtypep 'scheduler-queue-full 'scheduler-error))
  (t:true (subtypep 'scheduler-unknown-endpoint 'scheduler-error))
  (t:true (subtypep 'scheduler-error 'error))
  ;; Amendment-1 family — plain conditions, NOT errors
  (t:true (subtypep 'esi-skip 'esi-completion-event))
  (t:true (subtypep 'esi-failure 'esi-completion-event))
  (t:true (subtypep 'esi-completion-event 'condition))
  (t:false (subtypep 'esi-completion-event 'error))
  (t:false (subtypep 'esi-failure 'error))
  ;; Skip subclasses
  (t:true (subtypep 'esi-budget-exhausted 'esi-skip))
  (t:true (subtypep 'esi-deadline-missed 'esi-skip))
  (t:true (subtypep 'esi-cancelled 'esi-skip))
  ;; Failure subclasses
  (t:true (subtypep 'esi-http-error 'esi-failure))
  (t:true (subtypep 'esi-http-4xx-error 'esi-http-error))
  (t:true (subtypep 'esi-http-5xx-error 'esi-http-error))
  (t:true (subtypep 'esi-network-failure 'esi-failure))
  (t:true (subtypep 'esi-rate-limit-exhausted 'esi-failure)))
