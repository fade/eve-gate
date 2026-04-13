;;;; test/performance.lisp - Performance tests for eve-gate
;;;;
;;;; Automated performance tests that verify the system meets
;;;; established performance baselines. Unlike benchmarks (in dev/),
;;;; these are pass/fail tests suitable for CI.
;;;;
;;;; Performance targets:
;;;;   - Cache operations: < 1ms for get/put
;;;;   - Cache key generation: < 50μs
;;;;   - Middleware pipeline: < 100μs overhead
;;;;   - Rate limiter acquire: < 10μs
;;;;   - Memory: No significant leaks over iterations
;;;;
;;;; Usage:
;;;;   (asdf:load-system :eve-gate/test/performance)
;;;;   (parachute:test :eve-gate/test/performance)
;;;;
;;;; Or via Make:
;;;;   make test-performance

(uiop:define-package #:eve-gate/test/performance
  (:use #:cl)
  (:import-from #:eve-gate.cache
                #:make-memory-cache
                #:memory-cache-get
                #:memory-cache-put
                #:memory-cache-delete
                #:memory-cache-count
                #:memory-cache-statistics
                #:make-cache-manager
                #:cache-get
                #:cache-put
                #:make-cache-key)
  (:import-from #:eve-gate.core
                #:make-middleware
                #:make-middleware-stack
                #:apply-request-middleware
                #:apply-response-middleware
                #:make-http-client)
  (:import-from #:eve-gate.concurrent
                #:make-token-bucket
                #:bucket-try-acquire
                #:bucket-tokens-available)
  (:import-from #:eve-gate.utils
                #:get-precise-time
                #:elapsed-microseconds
                #:elapsed-milliseconds
                #:initialize-performance-subsystem
                #:fast-cache-key
                #:intern-string
                #:make-object-pool
                #:pool-acquire
                #:pool-release)
  (:import-from #:eve-gate.api
                #:json-name->lisp-name)
  (:local-nicknames (#:t #:parachute))
  (:export
   #:run-performance-tests
   #:*performance-iterations*))

(in-package #:eve-gate/test/performance)

;;; ---------------------------------------------------------------------------
;;; Test configuration
;;; ---------------------------------------------------------------------------

(defparameter *performance-iterations* 10000
  "Number of iterations for performance tests.")

(defparameter *warmup-iterations* 1000
  "Number of warmup iterations before measurement.")

(defmacro with-timing ((var) &body body)
  "Execute BODY and bind elapsed microseconds to VAR."
  (let ((start (gensym "START")))
    `(let ((,start (get-precise-time)))
       (progn ,@body)
       (let ((,var (elapsed-microseconds ,start)))
         ,var))))

(defun run-measured-iterations (body-fn iterations warmup)
  "Run BODY-FN for WARMUP iterations, then measure ITERATIONS.
Returns (VALUES average-us total-us iterations)."
  ;; Warmup
  (dotimes (i warmup)
    (funcall body-fn))
  ;; Measure
  (let ((start (get-precise-time)))
    (dotimes (i iterations)
      (funcall body-fn))
    (let ((total-us (elapsed-microseconds start)))
      (values (/ total-us iterations)
              total-us
              iterations))))

(defmacro measure-average-time ((&key (iterations '*performance-iterations*)
                                      (warmup '*warmup-iterations*))
                                &body body)
  "Measure average execution time in microseconds.
Returns (VALUES average-us total-us iterations)."
  `(run-measured-iterations (lambda () ,@body) ,iterations ,warmup))

;;; ---------------------------------------------------------------------------
;;; Test suite definition (must be defined before child tests)
;;; ---------------------------------------------------------------------------

(t:define-test performance-tests
  "Performance test suite - verifies system meets performance baselines")

;;; ---------------------------------------------------------------------------
;;; Memory cache performance tests
;;; ---------------------------------------------------------------------------

(t:define-test perf/memory-cache-get-hit
  "Memory cache GET (hit) should be < 50μs average"
  
  (let ((cache (make-memory-cache :max-entries 10000)))
    ;; Pre-populate
    (dotimes (i 1000)
      (memory-cache-put cache (format nil "key-~D" i) (format nil "value-~D" i)))
    ;; Measure
    (let ((avg-us (measure-average-time (:iterations 10000)
                    (memory-cache-get cache (format nil "key-~D" (random 1000))))))
      (t:true (< avg-us 50)
              "Cache GET should average < 50μs, got ~,2Fμs" avg-us))))

(t:define-test perf/memory-cache-get-miss
  "Memory cache GET (miss) should be < 50μs average"
  
  (let ((cache (make-memory-cache :max-entries 10000)))
    (let ((avg-us (measure-average-time (:iterations 10000)
                    (memory-cache-get cache (format nil "missing-~D" (random 10000))))))
      (t:true (< avg-us 50)
              "Cache miss should average < 50μs, got ~,2Fμs" avg-us))))

(t:define-test perf/memory-cache-put
  "Memory cache PUT should be < 100μs average"
  
  (let ((cache (make-memory-cache :max-entries 20000)))
    (let ((avg-us (measure-average-time (:iterations 10000)
                    (memory-cache-put cache 
                                      (format nil "key-~D" (random 20000))
                                      "test-value"
                                      :ttl 300))))
      (t:true (< avg-us 100)
              "Cache PUT should average < 100μs, got ~,2Fμs" avg-us))))

(t:define-test perf/memory-cache-eviction
  "Memory cache eviction should not degrade performance"
  
  (let ((cache (make-memory-cache :max-entries 1000)))
    ;; Fill beyond capacity to trigger eviction
    (let ((avg-us (measure-average-time (:iterations 5000)
                    (memory-cache-put cache
                                      (format nil "evict-key-~D" (random 10000))
                                      "value"
                                      :ttl 300))))
      ;; Even with eviction, should be < 200μs
      (t:true (< avg-us 200)
              "Cache PUT with eviction should average < 200μs, got ~,2Fμs" avg-us))))

;;; ---------------------------------------------------------------------------
;;; Cache key generation performance tests
;;; ---------------------------------------------------------------------------

(t:define-test perf/cache-key-generation
  "Cache key generation should be < 20μs average"
  
  (let ((endpoint "/v5/characters/95465499/assets")
        (params '(("page" . "1") ("datasource" . "tranquility")))
        (auth "95465499")
        (ds "tranquility"))
    (let ((avg-us (measure-average-time (:iterations 50000)
                    (make-cache-key endpoint :params params 
                                            :auth-context auth 
                                            :datasource ds))))
      (t:true (< avg-us 20)
              "Cache key generation should average < 20μs, got ~,2Fμs" avg-us))))

(t:define-test perf/fast-cache-key
  "Optimized cache key should be < 10μs average"
  
  (initialize-performance-subsystem)
  (let ((endpoint "/v5/characters/95465499/assets")
        (params '(("page" . "1") ("datasource" . "tranquility")))
        (auth "95465499")
        (ds "tranquility"))
    (let ((avg-us (measure-average-time (:iterations 50000)
                    (fast-cache-key endpoint params auth ds))))
      (t:true (< avg-us 10)
              "Fast cache key should average < 10μs, got ~,2Fμs" avg-us))))

;;; ---------------------------------------------------------------------------
;;; Middleware performance tests
;;; ---------------------------------------------------------------------------

(t:define-test perf/middleware-pipeline-overhead
  "Middleware pipeline should add < 50μs overhead"
  
  (let* ((mw1 (make-middleware :name :perf1 :priority 10
                               :request-fn (lambda (ctx) ctx)))
         (mw2 (make-middleware :name :perf2 :priority 20
                               :request-fn (lambda (ctx) ctx)))
         (mw3 (make-middleware :name :perf3 :priority 30
                               :request-fn (lambda (ctx) ctx)))
         (stack (make-middleware-stack mw1 mw2 mw3))
         (ctx '(:method :get :path "/test" :headers ())))
    (let ((avg-us (measure-average-time (:iterations 10000)
                    (apply-request-middleware stack ctx))))
      (t:true (< avg-us 50)
              "Middleware pipeline should average < 50μs, got ~,2Fμs" avg-us))))

(t:define-test perf/middleware-response-processing
  "Response middleware should add < 50μs overhead"
  
  (let* ((mw (make-middleware :name :perf-resp :priority 10
                              :response-fn (lambda (resp ctx) 
                                            (declare (ignore ctx))
                                            resp)))
         (stack (make-middleware-stack mw))
         (resp '(:status 200 :body "test"))
         (ctx '(:method :get)))
    (let ((avg-us (measure-average-time (:iterations 10000)
                    (apply-response-middleware stack resp ctx))))
      (t:true (< avg-us 50)
              "Response middleware should average < 50μs, got ~,2Fμs" avg-us))))

;;; ---------------------------------------------------------------------------
;;; Rate limiter performance tests
;;; ---------------------------------------------------------------------------

(t:define-test perf/token-bucket-acquire
  "Token bucket acquire should be < 5μs average"
  
  (let ((bucket (make-token-bucket :max-tokens 1000 :refill-rate 100)))
    (let ((avg-us (measure-average-time (:iterations 10000)
                    (bucket-try-acquire bucket))))
      (t:true (< avg-us 5)
              "Token acquire should average < 5μs, got ~,2Fμs" avg-us))))

(t:define-test perf/token-bucket-check
  "Token bucket status check should be < 2μs average"
  
  (let ((bucket (make-token-bucket :max-tokens 1000 :refill-rate 100)))
    (let ((avg-us (measure-average-time (:iterations 50000)
                    (bucket-tokens-available bucket))))
      (t:true (< avg-us 2)
              "Token check should average < 2μs, got ~,2Fμs" avg-us))))

;;; ---------------------------------------------------------------------------
;;; String interning performance tests
;;; ---------------------------------------------------------------------------

(t:define-test perf/string-interning
  "String interning should be < 1μs for cached strings"
  
  (initialize-performance-subsystem)
  ;; Pre-intern some strings
  (dolist (s '("tranquility" "en" "application/json" "get" "post"))
    (intern-string s))
  (let ((avg-us (measure-average-time (:iterations 100000)
                  (intern-string "tranquility"))))
    (t:true (< avg-us 1)
            "Interned string lookup should average < 1μs, got ~,2Fμs" avg-us)))

;;; ---------------------------------------------------------------------------
;;; Object pool performance tests  
;;; ---------------------------------------------------------------------------

(t:define-test perf/object-pool-cycle
  "Object pool acquire/release should be < 2μs average"
  
  (let ((pool (make-object-pool "perf-pool"
                                (lambda () (make-array 64))
                                :max-size 32
                                :pre-fill 16)))
    (let ((avg-us (measure-average-time (:iterations 50000)
                    (let ((obj (pool-acquire pool)))
                      (pool-release pool obj)))))
      (t:true (< avg-us 2)
              "Pool cycle should average < 2μs, got ~,2Fμs" avg-us))))

;;; ---------------------------------------------------------------------------
;;; JSON name conversion performance tests
;;; ---------------------------------------------------------------------------

(t:define-test perf/json-name-conversion
  "JSON name to Lisp name conversion should be < 5μs"
  
  (let ((test-names '("character_id" "corporation_id" "solar_system_id"
                      "type_id" "market_group_id" "alliance_id")))
    (let ((avg-us (measure-average-time (:iterations 50000)
                    (json-name->lisp-name 
                     (nth (random (length test-names)) test-names)))))
      (t:true (< avg-us 5)
              "Name conversion should average < 5μs, got ~,2Fμs" avg-us))))

;;; ---------------------------------------------------------------------------
;;; Memory stability tests
;;; ---------------------------------------------------------------------------

(t:define-test perf/memory-stability-cache
  "Cache operations should not leak memory over iterations"
  
  (let ((cache (make-memory-cache :max-entries 1000)))
    ;; Run many operations
    (dotimes (i 10000)
      (memory-cache-put cache (format nil "leak-key-~D" (mod i 500)) "value")
      (memory-cache-get cache (format nil "leak-key-~D" (random 500)))
      (when (zerop (mod i 100))
        (memory-cache-delete cache (format nil "leak-key-~D" (random 500)))))
    ;; Cache count should be bounded
    (t:true (<= (memory-cache-count cache) 1000)
            "Cache should respect max-entries limit")))

(t:define-test perf/cache-manager-stability
  "Cache manager should handle sustained load"
  
  (let ((manager (make-cache-manager)))
    ;; Sustained operations
    (dotimes (i 5000)
      (cache-put manager (format nil "mgr-key-~D" (mod i 200)) 
                 (format nil "value-~D" i))
      (cache-get manager (format nil "mgr-key-~D" (random 200))))
    ;; Should complete without error
    (t:true t "Cache manager handled sustained load")))

;;; ---------------------------------------------------------------------------
;;; HTTP client initialization performance
;;; ---------------------------------------------------------------------------

(t:define-test perf/http-client-creation
  "HTTP client creation should be < 1ms"
  
  (let ((avg-us (measure-average-time (:iterations 100 :warmup 10)
                  (make-http-client))))
    (t:true (< avg-us 1000)
            "HTTP client creation should average < 1ms, got ~,2Fμs" avg-us)))

;;; ---------------------------------------------------------------------------
;;; Concurrent operation stress test
;;; ---------------------------------------------------------------------------

(t:define-test perf/concurrent-cache-stress
  "Cache should handle concurrent-style access patterns"
  
  (let ((cache (make-memory-cache :max-entries 5000))
        (operations 0))
    ;; Simulate concurrent-style access (sequential but interleaved patterns)
    (dotimes (batch 100)
      ;; Batch of writes
      (dotimes (i 50)
        (memory-cache-put cache 
                          (format nil "batch-~D-key-~D" batch i)
                          (format nil "value-~D" i))
        (incf operations))
      ;; Batch of reads
      (dotimes (i 50)
        (memory-cache-get cache (format nil "batch-~D-key-~D" (random (1+ batch)) (random 50)))
        (incf operations)))
    (let ((stats (memory-cache-statistics cache)))
      (t:true (> (getf stats :hit-rate) 0)
              "Should achieve some cache hits under stress"))))

;;; ---------------------------------------------------------------------------
;;; Test runner
;;; ---------------------------------------------------------------------------

(defun run-performance-tests (&key (verbose t))
  "Run all performance tests.

Returns the test report. Set VERBOSE to NIL for quieter output."
  (format t "~&=== EVE-GATE Performance Tests ===~%")
  (format t "Iterations per test: ~D~%" *performance-iterations*)
  (format t "Warmup iterations: ~D~%~%" *warmup-iterations*)
  ;; Initialize subsystems
  (initialize-performance-subsystem)
  ;; Run tests
  (let ((report (t:test 'performance-tests 
                        :report (if verbose 
                                    'parachute:interactive 
                                    'parachute:plain))))
    (format t "~&Performance tests complete.~%")
    report))
