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
                #:make-queued-request)
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
