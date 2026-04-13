;;;; job-queue.lisp - Persistent job queue for background ESI operations
;;;;
;;;; Provides a higher-level job abstraction over the request queue. Jobs
;;;; are named, trackable units of work that can contain multiple requests,
;;;; have dependencies, and maintain state across retries.
;;;;
;;;; Use cases:
;;;;   - Background data refresh (periodically update cached data)
;;;;   - Multi-step workflows (fetch character, then corp, then alliance)
;;;;   - Scheduled operations (market data snapshots)
;;;;   - Batch imports (load historical data)
;;;;
;;;; Jobs differ from raw requests in that they:
;;;;   - Have a lifecycle: :pending -> :running -> :completed / :failed
;;;;   - Can contain multiple requests that form a logical unit
;;;;   - Support retry with configurable backoff
;;;;   - Can depend on other jobs completing first
;;;;   - Track elapsed time and attempt counts

(in-package #:eve-gate.concurrent)

;;; ---------------------------------------------------------------------------
;;; Job structure
;;; ---------------------------------------------------------------------------

(defstruct (job (:constructor %make-job))
  "A named, trackable unit of work containing one or more ESI requests.

Slots:
  ID: Unique identifier for this job
  NAME: Human-readable job name
  STATUS: Current lifecycle state (:pending, :running, :completed, :failed, :cancelled)
  WORK-FN: Function (engine) -> result that performs the actual work
  RESULT: The final result value (set on completion)
  ERROR: The error condition (set on failure)
  PRIORITY: Job priority (maps to request priority)
  MAX-RETRIES: Maximum retry attempts
  RETRY-COUNT: Current retry attempt number
  RETRY-DELAY: Base delay between retries (seconds, exponentially scaled)
  DEPENDENCIES: List of job IDs that must complete before this job runs
  CREATED-AT: Universal-time when job was created
  STARTED-AT: Universal-time when job started executing
  COMPLETED-AT: Universal-time when job finished
  TAGS: Keyword list for categorization and querying
  RESULT-LOCK: Lock for synchronous result waiting
  RESULT-CV: Condition variable for synchronous waiting"
  (id (gensym "JOB-") :type symbol)
  (name "" :type string)
  (status :pending :type keyword)
  (work-fn nil :type (or null function))
  (result nil)
  (error nil)
  (priority +priority-normal+ :type (integer 0 4))
  (max-retries 3 :type (integer 0))
  (retry-count 0 :type (integer 0))
  (retry-delay 1.0 :type single-float)
  (dependencies nil :type list)
  (created-at (get-universal-time) :type integer)
  (started-at 0 :type integer)
  (completed-at 0 :type integer)
  (tags nil :type list)
  (result-lock (bt:make-lock "job-result-lock"))
  (result-cv (bt:make-condition-variable :name "job-result-cv")))

(defun make-job (name work-fn &key (priority +priority-normal+)
                                     (max-retries 3)
                                     (retry-delay 1.0)
                                     dependencies
                                     tags)
  "Create a new job.

NAME: Human-readable job name
WORK-FN: Function (engine) -> result that performs the work
PRIORITY: Job priority 0-4 (default: +priority-normal+)
MAX-RETRIES: Maximum retry attempts (default: 3)
RETRY-DELAY: Base retry delay in seconds (default: 1.0)
DEPENDENCIES: List of job IDs that must complete first
TAGS: Keyword list for categorization

Returns a job struct.

Example:
  (make-job \"fetch-character-95465499\"
    (lambda (engine)
      (submit-and-wait engine \"/v5/characters/95465499/\"))
    :tags '(:character :profile))"
  (%make-job
   :name name
   :work-fn work-fn
   :priority priority
   :max-retries max-retries
   :retry-delay (float retry-delay)
   :dependencies (copy-list dependencies)
   :tags (copy-list tags)))

;;; ---------------------------------------------------------------------------
;;; Job lifecycle operations
;;; ---------------------------------------------------------------------------

(defun job-complete-p (job)
  "Return T if the job has reached a terminal state."
  (not (null (member (job-status job) '(:completed :failed :cancelled)))))

(defun job-runnable-p (job resolved-job-ids)
  "Return T if the job is pending and all dependencies are satisfied.

JOB: A job struct
RESOLVED-JOB-IDS: Set of job IDs that have completed successfully"
  (and (eq (job-status job) :pending)
       (every (lambda (dep-id)
                (member dep-id resolved-job-ids))
              (job-dependencies job))))

(defun complete-job (job result)
  "Mark JOB as completed with RESULT.

JOB: A job struct
RESULT: The final result value"
  (setf (job-result job) result
        (job-status job) :completed
        (job-completed-at job) (get-universal-time))
  (bt:with-lock-held ((job-result-lock job))
    (bt:condition-notify (job-result-cv job)))
  job)

(defun fail-job (job error)
  "Mark JOB as failed with ERROR condition.

JOB: A job struct
ERROR: The error condition"
  (setf (job-error job) error
        (job-status job) :failed
        (job-completed-at job) (get-universal-time))
  (bt:with-lock-held ((job-result-lock job))
    (bt:condition-notify (job-result-cv job)))
  job)

(defun cancel-job (job)
  "Cancel a pending or running job.

JOB: A job struct"
  (unless (job-complete-p job)
    (setf (job-status job) :cancelled
          (job-completed-at job) (get-universal-time))
    (bt:with-lock-held ((job-result-lock job))
      (bt:condition-notify (job-result-cv job))))
  job)

(defun wait-for-job (job &key (timeout 120))
  "Block until JOB completes or times out.

JOB: A job struct
TIMEOUT: Maximum seconds to wait (default: 120)

Returns two values:
  1. The job result (or NIL)
  2. The job status keyword"
  (bt:with-lock-held ((job-result-lock job))
    (loop until (job-complete-p job)
          do (unless (bt:condition-wait
                       (job-result-cv job)
                       (job-result-lock job)
                       :timeout timeout)
               (return-from wait-for-job
                 (values nil :timeout)))))
  (values (job-result job) (job-status job)))

(defun job-elapsed-time (job)
  "Return elapsed time for the job in seconds.

For running jobs, returns time since start. For completed jobs,
returns total execution time."
  (cond
    ((zerop (job-started-at job)) 0)
    ((job-complete-p job)
     (- (job-completed-at job) (job-started-at job)))
    (t (- (get-universal-time) (job-started-at job)))))

;;; ---------------------------------------------------------------------------
;;; Job queue
;;; ---------------------------------------------------------------------------

(defstruct (job-queue (:constructor %make-job-queue))
  "Queue for managing and executing jobs.

Slots:
  LOCK: Thread synchronization lock
  JOBS: Hash-table of job-id -> job
  PENDING: List of pending job IDs in priority order
  COMPLETED-IDS: List of successfully completed job IDs (for dependency tracking)
  ENGINE: Concurrent engine for job execution
  PROCESSOR-THREAD: Background thread processing jobs
  RUNNING-P: Whether the queue is active
  MAX-CONCURRENT: Maximum simultaneously running jobs
  CURRENTLY-RUNNING: Current number of running jobs"
  (lock (bt:make-lock "job-queue-lock"))
  (jobs (make-hash-table :test 'eq) :type hash-table)
  (pending nil :type list)
  (completed-ids nil :type list)
  (engine nil :type (or null concurrent-engine))
  (processor-thread nil)
  (running-p nil :type boolean)
  (max-concurrent 4 :type (integer 1))
  (currently-running 0 :type (integer 0)))

(defun make-job-queue (&key engine (max-concurrent 4))
  "Create a job queue.

ENGINE: Concurrent engine for executing jobs (default: creates one)
MAX-CONCURRENT: Maximum simultaneously running jobs (default: 4)

Returns a job-queue struct."
  (%make-job-queue
   :engine (or engine (make-concurrent-engine :worker-count 4))
   :max-concurrent max-concurrent))

;;; ---------------------------------------------------------------------------
;;; Job queue operations
;;; ---------------------------------------------------------------------------

(defun enqueue-job (queue job)
  "Add a job to the queue.

QUEUE: A job-queue struct
JOB: A job struct

Returns the job."
  (bt:with-lock-held ((job-queue-lock queue))
    (setf (gethash (job-id job) (job-queue-jobs queue)) job)
    ;; Insert maintaining priority order (lower number = higher priority)
    (setf (job-queue-pending queue)
          (merge 'list
                 (list (job-id job))
                 (job-queue-pending queue)
                 (lambda (a b)
                   (let ((job-a (gethash a (job-queue-jobs queue)))
                         (job-b (gethash b (job-queue-jobs queue))))
                     (< (job-priority job-a) (job-priority job-b)))))))
  job)

(defun process-jobs (queue)
  "Start background job processing.

QUEUE: A job-queue struct

Returns the queue."
  (bt:with-lock-held ((job-queue-lock queue))
    (when (job-queue-running-p queue)
      (return-from process-jobs queue))
    (setf (job-queue-running-p queue) t)
    ;; Ensure engine is running
    (start-engine (job-queue-engine queue))
    ;; Start processor thread
    (setf (job-queue-processor-thread queue)
          (bt:make-thread
           (lambda () (job-processor-loop queue))
           :name "eve-gate-job-processor")))
  (log-info "Job queue processing started")
  queue)

(defun stop-job-processing (queue &key (wait t))
  "Stop job processing.

QUEUE: A job-queue struct
WAIT: If T, wait for running jobs (default: T)"
  (bt:with-lock-held ((job-queue-lock queue))
    (unless (job-queue-running-p queue)
      (return-from stop-job-processing queue))
    (setf (job-queue-running-p queue) nil))
  (when (and wait
             (job-queue-processor-thread queue)
             (bt:thread-alive-p (job-queue-processor-thread queue)))
    (bt:join-thread (job-queue-processor-thread queue)))
  (log-info "Job queue processing stopped")
  queue)

;;; ---------------------------------------------------------------------------
;;; Job processor
;;; ---------------------------------------------------------------------------

(defun job-processor-loop (queue)
  "Background loop that dispatches runnable jobs.

Continuously checks for pending jobs whose dependencies are satisfied
and dispatches them for execution, respecting the concurrency limit."
  (log-debug "Job processor started")
  (unwind-protect
       (loop while (job-queue-running-p queue)
             do (handler-case
                    (let ((dispatched (dispatch-ready-jobs queue)))
                      (unless dispatched
                        ;; No jobs ready — sleep briefly
                        (sleep 0.5)))
                  (error (e)
                    (log-error "Job processor error: ~A" e)
                    (sleep 1))))
    (log-debug "Job processor exiting")))

(defun dispatch-ready-jobs (queue)
  "Find and dispatch jobs that are ready to run.

QUEUE: A job-queue struct

Returns T if any jobs were dispatched."
  (bt:with-lock-held ((job-queue-lock queue))
    (when (>= (job-queue-currently-running queue)
              (job-queue-max-concurrent queue))
      (return-from dispatch-ready-jobs nil))
    (let ((completed-ids (job-queue-completed-ids queue))
          (dispatched nil))
      ;; Find runnable jobs
      (setf (job-queue-pending queue)
            (loop for job-id in (job-queue-pending queue)
                  for job = (gethash job-id (job-queue-jobs queue))
                  if (and job (job-runnable-p job completed-ids)
                          (< (job-queue-currently-running queue)
                             (job-queue-max-concurrent queue)))
                    do (incf (job-queue-currently-running queue))
                       (setf dispatched t)
                       (execute-job-async queue job)
                  else if (and job (not (job-complete-p job)))
                         collect job-id))
      dispatched)))

(defun execute-job-async (queue job)
  "Execute a job asynchronously in a new thread.

QUEUE: The job-queue (for completion notification)
JOB: The job to execute"
  (setf (job-status job) :running
        (job-started-at job) (get-universal-time))
  (bt:make-thread
   (lambda ()
     (execute-job-with-retries queue job))
   :name (format nil "eve-gate-job-~A" (job-name job))))

(defun execute-job-with-retries (queue job)
  "Execute a job, retrying on failure up to max-retries.

QUEUE: The job-queue
JOB: The job to execute"
  (unwind-protect
       (loop
         (handler-case
             (let ((result (funcall (job-work-fn job)
                                    (job-queue-engine queue))))
               (complete-job job result)
               (return))
           (error (e)
             (incf (job-retry-count job))
             (if (< (job-retry-count job) (job-max-retries job))
                 (let ((delay (* (job-retry-delay job)
                                 (expt 2 (1- (job-retry-count job))))))
                   (log-warn "Job ~A failed (attempt ~D/~D), retrying in ~,1Fs: ~A"
                             (job-name job)
                             (job-retry-count job)
                             (job-max-retries job)
                             delay e)
                   (sleep delay))
                 (progn
                   (log-error "Job ~A failed after ~D attempts: ~A"
                              (job-name job)
                              (job-retry-count job) e)
                   (fail-job job e)
                   (return))))))
    ;; Update queue state
    (bt:with-lock-held ((job-queue-lock queue))
      (decf (job-queue-currently-running queue))
      (when (eq (job-status job) :completed)
        (push (job-id job) (job-queue-completed-ids queue))))))

;;; ---------------------------------------------------------------------------
;;; Job query and status
;;; ---------------------------------------------------------------------------

(defun job-status-query (queue &key status tags)
  "Query jobs by status and/or tags.

QUEUE: A job-queue struct
STATUS: Filter by status keyword (or NIL for all)
TAGS: Filter by tags (job must have all listed tags)

Returns a list of matching job structs."
  (let ((results '()))
    (bt:with-lock-held ((job-queue-lock queue))
      (maphash (lambda (id job)
                 (declare (ignore id))
                 (when (and (or (null status) (eq (job-status job) status))
                            (or (null tags)
                                (every (lambda (tag)
                                         (member tag (job-tags job)))
                                       tags)))
                   (push job results)))
               (job-queue-jobs queue)))
    results))

(defun job-queue-status (queue &optional (stream *standard-output*))
  "Print a status report of the job queue.

QUEUE: A job-queue struct
STREAM: Output stream (default: *standard-output*)"
  (format stream "~&=== Job Queue Status ===~%")
  (format stream "  Running: ~A~%" (job-queue-running-p queue))
  (format stream "  Concurrent: ~D / ~D~%"
          (job-queue-currently-running queue)
          (job-queue-max-concurrent queue))
  (let ((total 0) (pending 0) (running 0) (completed 0) (failed 0))
    (maphash (lambda (id job)
               (declare (ignore id))
               (incf total)
               (ecase (job-status job)
                 (:pending (incf pending))
                 (:running (incf running))
                 (:completed (incf completed))
                 (:failed (incf failed))
                 (:cancelled nil)))
             (job-queue-jobs queue))
    (format stream "~%  Jobs:~%")
    (format stream "    Total:     ~D~%" total)
    (format stream "    Pending:   ~D~%" pending)
    (format stream "    Running:   ~D~%" running)
    (format stream "    Completed: ~D~%" completed)
    (format stream "    Failed:    ~D~%" failed))
  (format stream "=== End Job Queue Status ===~%")
  queue)
