;;;; scheduler.lisp - Budget-aware priority request scheduler for eve-gate
;;;;
;;;; The request-scheduler is the public submission surface for consumers
;;;; that need deadline-aware, priority-driven, cache-coherent dispatch of
;;;; many ESI requests with predicted-budget backpressure.
;;;;
;;;; It wraps the existing concurrent-engine + esi-rate-limiter + cache-manager
;;;; and adds:
;;;;   - Explicit, named priority on every submission (no silent defaults).
;;;;   - Deadlines distinct from give-up timeouts.
;;;;   - In-flight-aware predicted-budget bookkeeping for proactive backpressure.
;;;;   - Cache short-circuit at submission time, before a rate-limit token is
;;;;     ever consumed for an entry that is still cache-fresh.
;;;;   - A separate bootstrap submission surface for bulk drains that pace
;;;;     themselves and yield to steady-state work.
;;;;   - A unified state accessor for harness telemetry, plus a per-completion
;;;;     callback contract that distinguishes :ok, :cache-hit, :skipped, and
;;;;     :failed outcomes so consumers can log skipped requests without
;;;;     red-flagging them as failures.
;;;;
;;;; Consumers submit refreshes via:
;;;;   (submit-refresh scheduler :operation-id 'get-markets-region-id-orders
;;;;                              :params '(:region-id 10000002 :type-id 34)
;;;;                              :priority :hot
;;;;                              :deadline-seconds 300
;;;;                              :on-complete fn
;;;;                              :on-skip fn
;;;;                              :on-fail fn)
;;;; or in bulk:
;;;;   (submit-refresh-batch scheduler specs :batch-id "heatmap-cycle-..." ...)
;;;;
;;;; A submission without an explicit :priority raises a `scheduler-missing-priority`
;;;; condition rather than silently defaulting. The reasoning: any consumer that
;;;; has enough information to ask the scheduler for a refresh also has enough
;;;; information to label its priority. A silent default would mask a heat-map
;;;; classification bug as warm-tier dispatch.
;;;;
;;;; This file lays the scaffolding: struct, lifecycle, the submission verbs,
;;;; the conditions family, and the dispatch path that hands work to the
;;;; engine. Cache short-circuit and budget-aware gating are layered on in
;;;; subsequent commits; bootstrap pool and cancellation/state observation
;;;; come after that.
;;;;
;;;; The completion events use the CL condition system rather than flat
;;;; keyword reasons. `esi-completion-event` is the abstract parent; `esi-skip`
;;;; and `esi-failure` are its abstract children; concrete subclasses cover
;;;; the failure modes here, with skip subclasses introduced by the commits
;;;; that produce them (budget gate, cancellation). The events are plain
;;;; conditions, not `error` subtypes — they're protocol-bearing objects
;;;; delivered through callbacks; consumers escalate via `(error event)` when
;;;; they want a debugger landing.

(in-package #:eve-gate.concurrent)

;;; ---------------------------------------------------------------------------
;;; Condition family
;;; ---------------------------------------------------------------------------

(define-condition scheduler-error (error)
  ((scheduler :initarg :scheduler :reader scheduler-error-scheduler
              :documentation "The request-scheduler instance, when relevant.")
   (operation-id :initarg :operation-id :initform nil
                 :reader scheduler-error-operation-id
                 :documentation "Operation ID (string or symbol) for the failing call, if any."))
  (:documentation "Parent class for all errors raised by request-scheduler.

Consumers can catch the whole family with (handler-case ... (scheduler-error (c) ...)).
Specialise via the subtypes below for finer-grained handling."))

(define-condition scheduler-missing-priority (scheduler-error)
  ((params :initarg :params :initform nil
           :reader scheduler-missing-priority-params
           :documentation "The params plist for the offending submission. Useful for
locating the bad call site in a heat-map-driven workload."))
  (:report
   (lambda (c stream)
     (format stream
             "submit-refresh called without :priority for operation-id ~S, params ~S. ~
              :priority must be one of :critical :hot :warm :cold (or :bootstrap via ~
              submit-bootstrap). The scheduler refuses to guess a tier because an ~
              omission is almost always a bug in the caller's heat-map code rather ~
              than a sensible default."
             (scheduler-error-operation-id c)
             (scheduler-missing-priority-params c))))
  (:documentation "Signaled when submit-refresh is called without :priority."))

(define-condition scheduler-invalid-priority (scheduler-error)
  ((priority :initarg :priority :reader scheduler-invalid-priority-value))
  (:report
   (lambda (c stream)
     (format stream
             "submit-refresh called with unknown :priority ~S for operation-id ~S. ~
              Accepted: :critical :hot :warm :cold. Use submit-bootstrap for bulk drains."
             (scheduler-invalid-priority-value c)
             (scheduler-error-operation-id c))))
  (:documentation "Signaled when :priority is supplied but not in the accepted set."))

(define-condition scheduler-not-running (scheduler-error)
  ()
  (:report
   (lambda (c stream)
     (format stream "Cannot submit to a stopped request-scheduler (~S)."
             (scheduler-error-scheduler c))))
  (:documentation "Signaled when a submission targets a scheduler that has not been started or has already been stopped."))

(define-condition scheduler-queue-full (scheduler-error)
  ((priority :initarg :priority :initform nil
             :reader scheduler-queue-full-priority))
  (:report
   (lambda (c stream)
     (format stream
             "Steady-state queue is full; cannot enqueue ~S (priority ~S). ~
              Configure :max-queue-depth on make-request-scheduler or submit via ~
              submit-bootstrap if this is bulk-class work."
             (scheduler-error-operation-id c)
             (scheduler-queue-full-priority c))))
  (:documentation "Signaled when submit-refresh would push the steady-state queue past :max-queue-depth."))

(define-condition scheduler-unknown-endpoint (scheduler-error)
  ()
  (:report
   (lambda (c stream)
     (format stream
             "operation-id ~S did not resolve to a known endpoint via find-endpoint."
             (scheduler-error-operation-id c))))
  (:documentation "Signaled when the operation-id cannot be located in the endpoint registry."))

;;; ---------------------------------------------------------------------------
;;; Completion event family — plain conditions delivered via callback
;;; ---------------------------------------------------------------------------
;;;
;;; These are NOT subtypes of `error`. They are protocol-bearing condition
;;; instances attached to the `event` slot of `refresh-completion` for
;;; exceptional outcomes (`:skipped` and `:failed`). Consumer code that wants
;;; debugger landing escalates explicitly via `(error event)`.

(define-condition esi-completion-event ()
  ((scheduler :initarg :scheduler :initform nil
              :reader esi-completion-event-scheduler)
   (handle :initarg :handle :initform nil
           :reader esi-completion-event-handle)
   (operation-id :initarg :operation-id :initform nil
                 :reader esi-completion-event-operation-id)
   (endpoint :initarg :endpoint :initform ""
             :reader esi-completion-event-endpoint)
   (batch-id :initarg :batch-id :initform nil
             :reader esi-completion-event-batch-id)
   (enqueued-at :initarg :enqueued-at :initform 0
                :reader esi-completion-event-enqueued-at)
   (completed-at :initarg :completed-at :initform 0
                 :reader esi-completion-event-completed-at)
   (wait-time :initarg :wait-time :initform 0.0
              :reader esi-completion-event-wait-time))
  (:documentation "Abstract parent for asynchronous scheduler completion events.

Carried in the `event` slot of `refresh-completion` for :skipped and :failed
outcomes. Consumers can catch families via type predicates or `handler-bind`
after `(signal event)` (Shape C in the amendment) or pattern-match with
`typecase` (Shape B)."))

(define-condition esi-skip (esi-completion-event)
  ((deadline-remaining-at-skip :initarg :deadline-remaining-at-skip
                               :initform nil
                               :reader esi-skip-deadline-remaining))
  (:documentation "Abstract parent for skipped outcomes (no HTTP performed).

Concrete subclasses — esi-budget-exhausted, esi-deadline-missed, esi-cancelled,
esi-queue-full — are introduced by the commits that produce them."))

(define-condition esi-failure (esi-completion-event)
  ((attempt-count :initarg :attempt-count :initform 1
                  :reader esi-failure-attempt-count))
  (:documentation "Abstract parent for failed outcomes (HTTP attempted, terminal error)."))

(define-condition esi-http-error (esi-failure)
  ((status :initarg :status :initform nil
           :reader esi-http-error-status)
   (response-body :initarg :response-body :initform nil
                  :reader esi-http-error-response-body)
   (response-headers :initarg :response-headers :initform nil
                     :reader esi-http-error-response-headers))
  (:report
   (lambda (c stream)
     (format stream "ESI HTTP ~A for ~A (~A)"
             (esi-http-error-status c)
             (esi-completion-event-endpoint c)
             (esi-completion-event-operation-id c))))
  (:documentation "Abstract parent for HTTP-level scheduler failures."))

(define-condition esi-http-4xx-error (esi-http-error)
  ()
  (:documentation "HTTP 4xx response: client-side problem (bad request, auth, etc.)."))

(define-condition esi-http-5xx-error (esi-http-error)
  ()
  (:documentation "HTTP 5xx response: server-side problem (502/503/504)."))

(define-condition esi-network-failure (esi-failure)
  ((cause :initarg :cause :initform nil
          :reader esi-network-failure-cause))
  (:report
   (lambda (c stream)
     (format stream "ESI network failure for ~A: ~A"
             (esi-completion-event-endpoint c)
             (esi-network-failure-cause c))))
  (:documentation "Connection/timeout/DNS failure. CAUSE wraps the original condition.

Named `esi-network-failure` rather than `esi-network-error` because the latter
is already a class in `eve-gate.core` (a subtype of `esi-error`) and the
concurrent package uses that core package. The two represent different shapes:
`eve-gate.core:esi-network-error` is the wire-side error class signaled by
the HTTP client; `esi-network-failure` here is the scheduler-side completion
event delivered through a callback. The scheduler translates between them at
its boundary."))

(define-condition esi-budget-exhausted (esi-skip)
  ((limit-remain :initarg :limit-remain :initform nil
                 :reader esi-budget-exhausted-limit-remain
                 :documentation "Snapshot of X-ESI-Error-Limit-Remain when the skip was decided.")
   (predicted-remain :initarg :predicted-remain :initform nil
                     :reader esi-budget-exhausted-predicted-remain
                     :documentation "limit-remain minus in-flight minus jitter-margin.")
   (budget-threshold :initarg :budget-threshold :initform nil
                     :reader esi-budget-exhausted-budget-threshold)
   (in-flight :initarg :in-flight :initform nil
              :reader esi-budget-exhausted-in-flight))
  (:report
   (lambda (c stream)
     (format stream
             "ESI error budget exhausted for ~A: predicted-remain=~A (threshold=~A, in-flight=~A)"
             (esi-completion-event-endpoint c)
             (esi-budget-exhausted-predicted-remain c)
             (esi-budget-exhausted-budget-threshold c)
             (esi-budget-exhausted-in-flight c))))
  (:documentation "Skip event: budget was below threshold and stayed there past the deadline."))

(define-condition esi-deadline-missed (esi-skip)
  ((time-in-queue :initarg :time-in-queue :initform nil
                  :reader esi-deadline-missed-time-in-queue
                  :documentation "Seconds the request spent waiting before being skipped."))
  (:report
   (lambda (c stream)
     (format stream "ESI deadline missed for ~A after ~As in queue"
             (esi-completion-event-endpoint c)
             (esi-deadline-missed-time-in-queue c))))
  (:documentation "Skip event: the request sat in the engine queue past its deadline.

Distinct from `esi-budget-exhausted` in that budget pressure was not the
cause — the queue was just slow. Currently delivered for engine-queue
expirations; held-queue expirations are reported as `esi-budget-exhausted`
because the only reason an item is held is that the budget gate was closed."))

(define-condition esi-rate-limit-exhausted (esi-failure)
  ((consecutive-420s :initarg :consecutive-420s :initform 0
                     :reader esi-rate-limit-exhausted-consecutive-420s)
   (backoff-window-attempted :initarg :backoff-window-attempted :initform 0
                             :reader esi-rate-limit-exhausted-backoff-window))
  (:report
   (lambda (c stream)
     (format stream "ESI 420 retries exhausted for ~A (~D consecutive)"
             (esi-completion-event-endpoint c)
             (esi-rate-limit-exhausted-consecutive-420s c))))
  (:documentation "420 retries exhausted by the 420-retry middleware."))

;;; ---------------------------------------------------------------------------
;;; Priority mapping
;;; ---------------------------------------------------------------------------

(defparameter *scheduler-priority-map*
  `((:critical . ,+priority-critical+)
    (:hot      . ,+priority-high+)
    (:warm     . ,+priority-normal+)
    (:cold     . ,+priority-low+))
  "Mapping from consumer-facing priority keywords to engine priority integers.
:bootstrap is intentionally absent — bootstrap submissions go through
submit-bootstrap, not submit-refresh, and land in a dedicated pool.")

(defparameter *scheduler-default-deadlines*
  '((:critical . 30)
    (:hot      . 300)
    (:warm     . 1800)
    (:cold     . 21600))
  "Default :deadline-seconds applied per priority when the consumer omits it.
HOT matches the 5-minute heat-map cadence; WARM matches 30 min; COLD matches
6 h. Consumers can override per submission.")

(defun resolve-priority-or-error (priority operation-id params)
  "Translate a consumer-facing :priority keyword to an engine priority integer.

Signals scheduler-missing-priority when PRIORITY is nil (the consumer omitted
it) or scheduler-invalid-priority when it is non-nil but not in the accepted
set. Returns the integer priority on success."
  (cond
    ((null priority)
     (error 'scheduler-missing-priority
            :scheduler nil
            :operation-id operation-id
            :params params))
    ((eq priority :bootstrap)
     (error 'scheduler-invalid-priority
            :scheduler nil
            :operation-id operation-id
            :priority priority))
    (t
     (let ((mapped (cdr (assoc priority *scheduler-priority-map* :test #'eq))))
       (or mapped
           (error 'scheduler-invalid-priority
                  :scheduler nil
                  :operation-id operation-id
                  :priority priority))))))

(defun default-deadline-for (priority)
  "Return the default deadline in seconds for PRIORITY."
  (or (cdr (assoc priority *scheduler-default-deadlines* :test #'eq))
      1800))

;;; ---------------------------------------------------------------------------
;;; Operation-id and parameter handling
;;; ---------------------------------------------------------------------------

(defun normalize-operation-id (operation-id)
  "Normalize an operation-id designator to the canonical underscore form used
by find-endpoint.

A string is returned as-is. A symbol is converted by lowercasing its name and
replacing hyphens with underscores: 'get-markets-region-id-orders becomes
\"get_markets_region_id_orders\". This matches ESI's swagger conventions."
  (etypecase operation-id
    (string operation-id)
    (symbol (string-downcase (substitute #\_ #\- (symbol-name operation-id))))))

(defun keyword-to-param-name (kw)
  "Convert a parameter keyword like :region-id to ESI's wire form \"region_id\"."
  (string-downcase (substitute #\_ #\- (symbol-name kw))))

(defun split-path-and-query-params (path-template params)
  "Given a PATH-TEMPLATE containing {param_name} placeholders and a PARAMS plist
of (:key value …) pairs, partition PARAMS into path-substitutions and remaining
query parameters.

Returns two values:
  1. An alist of (string . string) suitable for substitute-path-parameters.
  2. An alist of (string . string) suitable for the query-params slot of an
     http-request.

Parameter values are coerced to strings via princ-to-string."
  (let ((path-subs '())
        (query-pairs '()))
    (loop for (key value) on params by #'cddr
          for name = (keyword-to-param-name key)
          for marker = (format nil "{~A}" name)
          do (if (search marker path-template)
                 (push (cons name (princ-to-string value)) path-subs)
                 (push (cons name (princ-to-string value)) query-pairs)))
    (values (nreverse path-subs)
            (nreverse query-pairs))))

(defun ensure-endpoint-registry-populated ()
  "Populate the ESI endpoint registry if it is empty.

The generated `populate-endpoint-registry` is defined but not invoked at
system-load time, so a fresh image has an empty registry. The scheduler
relies on `find-endpoint` during submission and triggers the population
lazily here rather than forcing every consumer to remember to call it.

Idempotent: subsequent calls observe a non-empty registry and no-op."
  (when (zerop (hash-table-count eve-gate.api::*endpoint-registry*))
    (eve-gate.api:populate-endpoint-registry)))

(defun resolve-endpoint-or-error (operation-id)
  "Look up OPERATION-ID in the endpoint registry. Returns the metadata plist on
success. Signals scheduler-unknown-endpoint when not found."
  (let* ((op-string (normalize-operation-id operation-id))
         (meta (find-endpoint op-string)))
    (unless meta
      (error 'scheduler-unknown-endpoint
             :scheduler nil
             :operation-id operation-id))
    (values meta op-string)))

;;; ---------------------------------------------------------------------------
;;; Completion and handle structures
;;; ---------------------------------------------------------------------------

(defstruct (refresh-completion (:constructor %make-refresh-completion))
  "Typed result delivered to consumer callbacks when a refresh resolves.

OUTCOME is a denormalised keyword hint for ergonomic dispatch (Shape A in the
condition-protocol amendment). For :skipped and :failed outcomes, EVENT carries
a typed condition instance from the esi-completion-event hierarchy. Consumers
may pattern-match on the condition class (Shape B) or re-signal the event from
inside a `handler-bind` (Shape C). For :ok and :cache-hit, EVENT is nil and the
data lives on the struct.

Slots:
  OUTCOME           :ok | :cache-hit | :skipped | :failed
  EVENT             An esi-completion-event instance for :skipped and :failed;
                    nil for :ok and :cache-hit. The class of the event refines
                    the outcome (esi-budget-exhausted, esi-http-5xx-error, …).
  DATA              Parsed response body (for :ok and :cache-hit).
  RESPONSE          esi-response struct on :ok; nil for :cache-hit/:skipped/:failed.
  ETAG              ETag value if known (live response or cached entry).
  CACHE-TIER        :l1 | :l2 | nil. Non-nil only for :cache-hit.
  ATTEMPT-COUNT     1 for first try; higher when 420-retry middleware retried.
  ENQUEUED-AT       Universal-time at submit-refresh call.
  DISPATCHED-AT     Universal-time when a worker picked the request up; nil for
                    cache-hits and pre-dispatch skips.
  COMPLETED-AT      Universal-time when the completion was constructed.
  WAIT-TIME         Seconds spent in the queue before dispatch.
  RATE-LIMIT-WAIT   Seconds spent in the rate-limit token gate.
  HTTP-LATENCY      Seconds spent in HTTP I/O; nil for cache-hit/:skipped.
  ENDPOINT          Resolved path string, with path-params substituted.
  OPERATION-ID      Pass-through from the submission.
  BATCH-ID          Pass-through string for grouping in observation; nil if
                    none supplied."
  (outcome :ok :type keyword)
  (event nil)
  (data nil)
  (response nil)
  (etag nil :type (or null string))
  (cache-tier nil :type (or null keyword))
  (attempt-count 1 :type (integer 1))
  (enqueued-at 0 :type integer)
  (dispatched-at nil :type (or null integer))
  (completed-at 0 :type integer)
  (wait-time 0.0 :type single-float)
  (rate-limit-wait 0.0 :type single-float)
  (http-latency nil :type (or null single-float))
  (endpoint "" :type string)
  (operation-id nil)
  (batch-id nil :type (or null string)))

(defstruct (refresh-handle (:constructor %make-refresh-handle))
  "Opaque handle returned by submit-refresh, identifying the in-flight refresh.

Carries enough state for the scheduler to deliver completions, for consumers
to poll status without holding a callback, and for cancellation to find the
underlying queued-request when it has not yet dispatched.

Slots:
  ID              Symbol gensym for logging/tracking.
  SCHEDULER       Back-reference to the parent request-scheduler.
  OPERATION-ID    Pass-through.
  ENDPOINT        Resolved path string.
  PRIORITY        Consumer-facing priority keyword.
  DEADLINE-AT     Universal-time after which the request is expired pre-dispatch.
  BATCH-ID        Pass-through grouping string.
  STATUS          :pending | :dispatched | :completed | :cancelled.
  COMPLETION      The refresh-completion when STATUS is :completed/:cancelled; nil otherwise.
  QUEUED-REQUEST  The underlying engine queued-request, when dispatched via the queue.
  ON-COMPLETE / ON-SKIP / ON-FAIL  Consumer callbacks (any may be nil).
  LOCK            Lock guarding status and completion transitions."
  (id (gensym "REFRESH-") :type symbol)
  (scheduler nil)
  (operation-id nil)
  (endpoint "" :type string)
  (priority :warm :type keyword)
  (deadline-at 0 :type integer)
  (batch-id nil :type (or null string))
  (status :pending :type keyword)
  (completion nil :type (or null refresh-completion))
  (queued-request nil)
  (on-complete nil :type (or null function))
  (on-skip nil :type (or null function))
  (on-fail nil :type (or null function))
  (enqueued-at 0 :type integer)
  (lock (bt:make-lock "refresh-handle-lock")))

;;; Slot reads on `refresh-handle` are atomic at the word level on SBCL, so
;;; callers may read REFRESH-HANDLE-STATUS and REFRESH-HANDLE-COMPLETION
;;; (the auto-generated accessors) without acquiring the lock. The lock is
;;; held only for compound check-then-set transitions inside the scheduler.

;;; ---------------------------------------------------------------------------
;;; The scheduler struct
;;; ---------------------------------------------------------------------------

(defstruct (request-scheduler (:constructor %make-request-scheduler))
  "Public submission surface for budget-aware, deadline-driven, cache-coherent
ESI refresh dispatch.

The scheduler is a thin shell wrapping the existing concurrent-engine,
esi-rate-limiter, and cache-manager. It owns:
  - The in-flight counter for predicted-budget bookkeeping.
  - Per-submission handles and the failure ring buffer.
  - The bootstrap worker pool (constructed lazily on first submit-bootstrap).
  - The dispatch-gate state machine that pauses non-critical priorities when
    predicted-budget drops below threshold.

Slots:
  ENGINE              The concurrent-engine the steady-state queue drains into.
  CACHE-MANAGER       The cache-manager consulted at submission for the
                      cache short-circuit. May be nil; without it, every
                      submission dispatches.
  RATE-LIMITER        The esi-rate-limiter whose error-budget snapshot drives
                      the predicted-budget calculation.
  HTTP-CLIENT         The underlying http-client passed to the engine. Held
                      here for diagnostic and resolve-time access.
  BUDGET-THRESHOLD    predicted-remain below this pauses non-critical
                      dispatch.
  BUDGET-RESUME       predicted-remain at or above this resumes dispatch.
  JITTER-MARGIN       Extra subtraction applied to predicted-remain to absorb
                      races between header-snapshot and in-flight reality.
  MAX-QUEUE-DEPTH     Steady-state queue cap; submissions past this signal
                      scheduler-queue-full.
  WORKER-COUNT        Engine workers.
  RATE-LIMIT-TIMEOUT  Per-request token-acquire timeout.
  BOOTSTRAP-POOL      Lazily-constructed worker-pool for bulk drains; nil
                      until first submit-bootstrap call.
  BOOTSTRAP-QUEUE-DEPTH  Cap for the bootstrap pool's own queue.
  BOOTSTRAP-PACING    Bootstrap drain rate cap in requests per second.
  IN-FLIGHT-COUNT     Atomic counter of submitted-but-not-completed requests
                      across both steady-state and bootstrap paths.
  IN-FLIGHT-LOCK      Lock for in-flight-count updates.
  STATS-LOCK          Lock for scheduler-private counters.
  TOTAL-SUBMITTED / TOTAL-CACHE-HITS / TOTAL-DISPATCHED / TOTAL-SKIPPED /
  TOTAL-FAILED        Counters for the scheduler-state plist.
  SKIP-REASONS        Plist of (reason-keyword . count) for skipped requests.
  FAILURE-RING        Fixed-size ring buffer of recent failure entries.
  FAILURE-RING-SIZE   Configured ring size; defaults to 256.
  FAILURE-RING-INDEX  Next slot to overwrite.
  HANDLES             Hash-table of handle-id → handle for active submissions.
  HANDLES-LOCK        Lock for HANDLES.
  RUNNING-P           Lifecycle flag.
  LIFECYCLE-LOCK      Lock for start/stop transitions."
  (engine nil)
  (cache-manager nil)
  (rate-limiter nil)
  (http-client nil)
  (budget-threshold 30 :type integer)
  (budget-resume 50 :type integer)
  (jitter-margin 5 :type integer)
  (max-queue-depth 5000 :type (integer 1))
  (worker-count 8 :type (integer 1))
  (rate-limit-timeout 30.0 :type single-float)
  (bootstrap-pool nil)
  (bootstrap-queue-depth 80000 :type (integer 1))
  (bootstrap-pacing 5.0 :type single-float)
  (in-flight-count 0 :type (integer 0))
  (in-flight-lock (bt:make-lock "scheduler-in-flight-lock"))
  (stats-lock (bt:make-lock "scheduler-stats-lock"))
  (total-submitted 0 :type (integer 0))
  (total-cache-hits 0 :type (integer 0))
  (total-dispatched 0 :type (integer 0))
  (total-skipped 0 :type (integer 0))
  (total-failed 0 :type (integer 0))
  (skip-reasons nil :type list)
  (failure-ring nil)
  (failure-ring-size 256 :type (integer 1))
  (failure-ring-index 0 :type (integer 0))
  (handles (make-hash-table :test 'eq) :type hash-table)
  (handles-lock (bt:make-lock "scheduler-handles-lock"))
  ;; Budget-gate state: :open allows dispatch, :closed defers non-critical
  ;; submissions to the held-queue. Transitions are hysteresis-gated by
  ;; budget-threshold (open → closed) and budget-resume (closed → open).
  (gate-state :open :type keyword)
  (gate-state-lock (bt:make-lock "scheduler-gate-lock"))
  ;; Held-queue: vector indexed by engine priority (0..4) holding deferred
  ;; submission entries. Each entry is a plist (:handle :method :endpoint
  ;; :query-pairs). The dispatcher thread drains it when the gate is open.
  (held-queues (make-array 5 :initial-element nil) :type simple-vector)
  (held-queues-lock (bt:make-lock "scheduler-held-queues-lock"))
  (dispatcher-thread nil)
  (dispatcher-poll-interval 0.25 :type single-float)
  (running-p nil :type boolean)
  (lifecycle-lock (bt:make-lock "scheduler-lifecycle-lock")))

;;; ---------------------------------------------------------------------------
;;; In-flight counter
;;; ---------------------------------------------------------------------------

(defun incf-in-flight (scheduler)
  "Atomically increment SCHEDULER's in-flight counter."
  (bt:with-lock-held ((request-scheduler-in-flight-lock scheduler))
    (incf (request-scheduler-in-flight-count scheduler))))

(defun decf-in-flight (scheduler)
  "Atomically decrement SCHEDULER's in-flight counter. Floors at zero."
  (bt:with-lock-held ((request-scheduler-in-flight-lock scheduler))
    (when (plusp (request-scheduler-in-flight-count scheduler))
      (decf (request-scheduler-in-flight-count scheduler)))))

(defun scheduler-in-flight-count (scheduler)
  "Return SCHEDULER's current in-flight count. Thread-safe snapshot."
  (bt:with-lock-held ((request-scheduler-in-flight-lock scheduler))
    (request-scheduler-in-flight-count scheduler)))

(defun predicted-remain-of (scheduler)
  "Compute the scheduler's view of the ESI error budget after subtracting
already-dispatched-but-not-completed requests.

  predicted-remain = error-limit-remain - in-flight-count - jitter-margin

Floored at zero. The jitter-margin absorbs the gap between a header snapshot
and the moment a wave of responses subtracts from the budget."
  (let* ((limiter (request-scheduler-rate-limiter scheduler))
         (remain (esi-rate-limiter-error-limit-remain limiter))
         (in-flight (scheduler-in-flight-count scheduler))
         (jitter (request-scheduler-jitter-margin scheduler)))
    (max 0 (- remain in-flight jitter))))

(defun update-gate-state (scheduler)
  "Re-evaluate SCHEDULER's gate-state under hysteresis.

Transitions:
  :open   → :closed   when predicted-remain < budget-threshold
  :closed → :open     when predicted-remain >= budget-resume

Returns the new gate state."
  (bt:with-lock-held ((request-scheduler-gate-state-lock scheduler))
    (let ((predicted (predicted-remain-of scheduler))
          (state (request-scheduler-gate-state scheduler))
          (threshold (request-scheduler-budget-threshold scheduler))
          (resume (request-scheduler-budget-resume scheduler)))
      (cond
        ((and (eq state :open) (< predicted threshold))
         (setf (request-scheduler-gate-state scheduler) :closed)
         (log-warn "Scheduler gate closing: predicted-remain=~D < threshold=~D"
                   predicted threshold)
         :closed)
        ((and (eq state :closed) (>= predicted resume))
         (setf (request-scheduler-gate-state scheduler) :open)
         (log-info "Scheduler gate opening: predicted-remain=~D >= resume=~D"
                   predicted resume)
         :open)
        (t state)))))

(defun gate-open-for-priority-p (scheduler priority)
  "Return T if SCHEDULER's gate currently admits a submission of PRIORITY.

`:critical` always bypasses the gate. Other priorities admit only when the
gate is in the :open state. Calls UPDATE-GATE-STATE to pick up the latest
budget snapshot before deciding."
  (if (eq priority :critical)
      t
      (eq (update-gate-state scheduler) :open)))

(defun hold-submission (scheduler handle method endpoint query-pairs)
  "Park a non-dispatched submission on SCHEDULER's held-queue, indexed by
the handle's engine-priority. The dispatcher thread will either dispatch
the entry (when the gate opens) or skip it with `esi-budget-exhausted`
(when its deadline expires)."
  (let* ((engine-priority
           (cdr (assoc (refresh-handle-priority handle)
                       *scheduler-priority-map* :test #'eq)))
         (entry (list :handle handle
                      :method method
                      :endpoint endpoint
                      :query-pairs query-pairs)))
    (bt:with-lock-held ((request-scheduler-held-queues-lock scheduler))
      (let ((q (aref (request-scheduler-held-queues scheduler) engine-priority)))
        (setf (aref (request-scheduler-held-queues scheduler) engine-priority)
              (nconc q (list entry)))))))

(defun build-budget-exhausted-completion (scheduler handle predicted)
  "Construct a `:skipped` refresh-completion carrying an `esi-budget-exhausted`
event. Called by the dispatcher when a held submission's deadline arrives
before the gate opens."
  (let* ((now (get-universal-time))
         (enqueued-at (refresh-handle-enqueued-at handle))
         (event (make-condition
                 'esi-budget-exhausted
                 :scheduler scheduler
                 :handle handle
                 :operation-id (refresh-handle-operation-id handle)
                 :endpoint (refresh-handle-endpoint handle)
                 :batch-id (refresh-handle-batch-id handle)
                 :enqueued-at enqueued-at
                 :completed-at now
                 :wait-time (max 0.0 (float (- now enqueued-at)))
                 :deadline-remaining-at-skip 0
                 :limit-remain
                 (esi-rate-limiter-error-limit-remain
                  (request-scheduler-rate-limiter scheduler))
                 :predicted-remain predicted
                 :budget-threshold (request-scheduler-budget-threshold scheduler)
                 :in-flight (scheduler-in-flight-count scheduler))))
    (%make-refresh-completion
     :outcome :skipped
     :event event
     :enqueued-at enqueued-at
     :completed-at now
     :wait-time (max 0.0 (float (- now enqueued-at)))
     :endpoint (refresh-handle-endpoint handle)
     :operation-id (refresh-handle-operation-id handle)
     :batch-id (refresh-handle-batch-id handle))))

(defun drain-held-queues-once (scheduler)
  "Walk the held queues from highest priority to lowest, exactly once.

For each held entry in FIFO order within its priority:
  - If the handle has been cancelled, drop the entry silently (its
    completion was delivered through the cancellation path).
  - Else if the deadline has passed, skip it with esi-budget-exhausted.
  - Else if the gate is currently open for the entry's priority, dispatch.
  - Else leave the entry in place for the next sweep."
  (let ((now (get-universal-time)))
    (bt:with-lock-held ((request-scheduler-held-queues-lock scheduler))
      (loop for priority from 0 to 4 do
        (let ((q (aref (request-scheduler-held-queues scheduler) priority))
              (keep '()))
          (dolist (entry q)
            (let* ((handle (getf entry :handle))
                   (deadline (refresh-handle-deadline-at handle))
                   (status (refresh-handle-status handle)))
              (cond
                ((eq status :cancelled)
                 nil)
                ((> now deadline)
                 (deliver-completion
                  scheduler handle
                  (build-budget-exhausted-completion
                   scheduler handle (predicted-remain-of scheduler))))
                ((gate-open-for-priority-p
                  scheduler (refresh-handle-priority handle))
                 (dispatch-via-engine scheduler handle
                                      (getf entry :method)
                                      (getf entry :endpoint)
                                      (getf entry :query-pairs)))
                (t
                 (push entry keep)))))
          (setf (aref (request-scheduler-held-queues scheduler) priority)
                (nreverse keep)))))))

(defun dispatcher-loop (scheduler)
  "Main loop of the scheduler's dispatcher thread.

Wakes every DISPATCHER-POLL-INTERVAL seconds and calls
`drain-held-queues-once`. The interval defaults to 0.25s, which adds at
most that much latency to held submissions that become dispatchable
between sweeps. The thread exits cleanly when RUNNING-P flips to NIL."
  (log-debug "Scheduler dispatcher thread started")
  (unwind-protect
       (loop while (request-scheduler-running-p scheduler)
             do (handler-case (drain-held-queues-once scheduler)
                  (error (e)
                    (log-error "Scheduler dispatcher loop error: ~A" e)))
                (sleep (request-scheduler-dispatcher-poll-interval scheduler)))
    (log-debug "Scheduler dispatcher thread exiting")))

;;; ---------------------------------------------------------------------------
;;; Statistics helpers
;;; ---------------------------------------------------------------------------

(defun bump-stat (scheduler key)
  "Increment one of the scheduler's submitted/cache-hit/dispatched/skipped/failed
counters. Thread-safe."
  (bt:with-lock-held ((request-scheduler-stats-lock scheduler))
    (ecase key
      (:submitted   (incf (request-scheduler-total-submitted scheduler)))
      (:cache-hit   (incf (request-scheduler-total-cache-hits scheduler)))
      (:dispatched  (incf (request-scheduler-total-dispatched scheduler)))
      (:skipped     (incf (request-scheduler-total-skipped scheduler)))
      (:failed      (incf (request-scheduler-total-failed scheduler))))))

(defun record-skip-reason (scheduler reason)
  "Record a :skipped completion's REASON in the scheduler's skip-reasons plist."
  (bt:with-lock-held ((request-scheduler-stats-lock scheduler))
    (let* ((plist (request-scheduler-skip-reasons scheduler))
           (current (getf plist reason 0)))
      (setf (getf plist reason) (1+ current)
            (request-scheduler-skip-reasons scheduler) plist))))

(defun record-failure-in-ring (scheduler entry)
  "Append ENTRY to the scheduler's failure ring buffer, overwriting oldest."
  (bt:with-lock-held ((request-scheduler-stats-lock scheduler))
    (let* ((ring (request-scheduler-failure-ring scheduler))
           (size (request-scheduler-failure-ring-size scheduler))
           (idx (request-scheduler-failure-ring-index scheduler)))
      (setf (aref ring idx) entry
            (request-scheduler-failure-ring-index scheduler) (mod (1+ idx) size)))))

;;; ---------------------------------------------------------------------------
;;; Constructor
;;; ---------------------------------------------------------------------------

(defun make-request-scheduler (&key cache-manager
                                    rate-limiter
                                    http-client
                                    engine
                                    (budget-threshold 30)
                                    (budget-resume 50)
                                    (jitter-margin 5)
                                    (max-queue-depth 5000)
                                    (worker-count 8)
                                    (rate-limit-timeout 30.0)
                                    (bootstrap-queue-depth 80000)
                                    (bootstrap-pacing 5.0)
                                    (failure-ring-size 256)
                                    (dispatcher-poll-interval 0.25))
  "Create a request-scheduler with sane production defaults.

Most consumers supply :cache-manager (so the cache short-circuit is active)
and otherwise accept defaults. The scheduler will lazily build a rate-limiter,
an http-client, and an engine if not supplied. Sharing the limiter between
the http-client and the engine is handled automatically when both are
auto-built.

Returns a request-scheduler. Call start-scheduler to bring it online."
  (ensure-endpoint-registry-populated)
  (let* ((limiter (or rate-limiter (ensure-rate-limiter)))
         (client (or http-client
                     (make-eve-http-client :cache-manager cache-manager
                                            :rate-limiter limiter
                                            :rate-limit-timeout rate-limit-timeout)))
         (eng (or engine
                  (make-concurrent-engine :worker-count worker-count
                                          :queue-size max-queue-depth
                                          :http-client client
                                          :rate-limiter limiter)))
         (ring (make-array failure-ring-size :initial-element nil)))
    (%make-request-scheduler
     :engine eng
     :cache-manager cache-manager
     :rate-limiter limiter
     :http-client client
     :budget-threshold budget-threshold
     :budget-resume budget-resume
     :jitter-margin jitter-margin
     :max-queue-depth max-queue-depth
     :worker-count worker-count
     :rate-limit-timeout rate-limit-timeout
     :bootstrap-queue-depth bootstrap-queue-depth
     :bootstrap-pacing bootstrap-pacing
     :failure-ring ring
     :failure-ring-size failure-ring-size
     :dispatcher-poll-interval (float dispatcher-poll-interval))))

;;; ---------------------------------------------------------------------------
;;; Lifecycle
;;; ---------------------------------------------------------------------------

(defun start-scheduler (scheduler)
  "Bring SCHEDULER online. Starts the engine's worker threads and the
scheduler's dispatcher thread. Idempotent. Returns the scheduler."
  (bt:with-lock-held ((request-scheduler-lifecycle-lock scheduler))
    (unless (request-scheduler-running-p scheduler)
      (start-engine (request-scheduler-engine scheduler))
      (setf (request-scheduler-running-p scheduler) t
            (request-scheduler-dispatcher-thread scheduler)
            (bt:make-thread
             (lambda () (dispatcher-loop scheduler))
             :name "eve-gate-scheduler-dispatcher"))
      (log-info "Request scheduler started with ~D engine workers"
                (request-scheduler-worker-count scheduler))))
  scheduler)

(defun stop-scheduler (scheduler &key (wait t))
  "Take SCHEDULER offline. Stops the dispatcher thread, drains the engine
(if WAIT), and stops the bootstrap pool if it has been started.
Idempotent. Returns the scheduler."
  (bt:with-lock-held ((request-scheduler-lifecycle-lock scheduler))
    (when (request-scheduler-running-p scheduler)
      (setf (request-scheduler-running-p scheduler) nil)
      (let ((thread (request-scheduler-dispatcher-thread scheduler)))
        (when (and thread (bt:thread-alive-p thread) wait)
          (bt:join-thread thread))
        (setf (request-scheduler-dispatcher-thread scheduler) nil))
      (stop-engine (request-scheduler-engine scheduler) :wait wait)
      ;; Bootstrap pool is shut down here once that subsystem lands.
      (log-info "Request scheduler stopped")))
  scheduler)

(defmacro with-scheduler ((var &rest args) &body body)
  "Bind VAR to a fresh started scheduler for BODY, stopping it on unwind."
  `(let ((,var (make-request-scheduler ,@args)))
     (start-scheduler ,var)
     (unwind-protect
          (progn ,@body)
       (stop-scheduler ,var))))

(defun ensure-scheduler-running (scheduler operation-id)
  "Signal scheduler-not-running if SCHEDULER is not running."
  (unless (request-scheduler-running-p scheduler)
    (error 'scheduler-not-running
           :scheduler scheduler
           :operation-id operation-id)))

;;; ---------------------------------------------------------------------------
;;; Handle bookkeeping
;;; ---------------------------------------------------------------------------

(defun register-handle (scheduler handle)
  "Record HANDLE in the scheduler's handles table. Thread-safe."
  (bt:with-lock-held ((request-scheduler-handles-lock scheduler))
    (setf (gethash (refresh-handle-id handle)
                   (request-scheduler-handles scheduler))
          handle)))

(defun unregister-handle (scheduler handle)
  "Remove HANDLE from the scheduler's handles table. Thread-safe."
  (bt:with-lock-held ((request-scheduler-handles-lock scheduler))
    (remhash (refresh-handle-id handle)
             (request-scheduler-handles scheduler))))

;;; ---------------------------------------------------------------------------
;;; Completion delivery
;;; ---------------------------------------------------------------------------

(defun event-skip-reason-keyword (event)
  "Map an esi-skip instance to the stable telemetry keyword used in
scheduler-state's :skip-reasons plist.

Uses runtime class-name introspection so concrete skip subclasses introduced
in commits 5 and 7 do not need to be referenced here. The keyword is derived
by stripping the conventional `esi-` prefix from the class name: e.g.,
`esi-budget-exhausted` → :budget-exhausted."
  (when event
    (let* ((name (string (class-name (class-of event))))
           (stripped (if (and (>= (length name) 4)
                              (string= "ESI-" (subseq name 0 4)))
                         (subseq name 4)
                         name)))
      (intern stripped :keyword))))

(defun failure-ring-entry (completion handle)
  "Build a per-failure ring-buffer entry from COMPLETION and HANDLE.

The entry shape includes `:event-class` (class name symbol) and selected
slot data appropriate to the event class. The harness consumes both the
class name and the class-specific keys (e.g., `:event-status` for HTTP
errors)."
  (let* ((event (refresh-completion-event completion))
         (base (list :at (refresh-completion-completed-at completion)
                     :endpoint (refresh-completion-endpoint completion)
                     :operation-id (refresh-completion-operation-id completion)
                     :priority (refresh-handle-priority handle)
                     :batch-id (refresh-completion-batch-id completion)
                     :attempt (refresh-completion-attempt-count completion)
                     :event-class (and event (class-name (class-of event)))))
         (extras
           (typecase event
             (esi-http-error
              (list :event-status (esi-http-error-status event)))
             (esi-network-failure
              (list :event-cause
                    (and (esi-network-failure-cause event)
                         (princ-to-string (esi-network-failure-cause event)))))
             (esi-rate-limit-exhausted
              (list :event-consecutive-420s
                    (esi-rate-limit-exhausted-consecutive-420s event)))
             (t nil))))
    (append base extras)))

(defun deliver-completion (scheduler handle completion)
  "Attach COMPLETION to HANDLE, transition its status, fire the appropriate
callback, update statistics, and remove the handle from the active set.

Safe to call exactly once per handle; further calls are silently ignored."
  (let (callback)
    (bt:with-lock-held ((refresh-handle-lock handle))
      (when (member (refresh-handle-status handle) '(:completed :cancelled))
        (return-from deliver-completion))
      (setf (slot-value handle 'completion) completion
            (slot-value handle 'status) :completed)
      (setf callback
            (case (refresh-completion-outcome completion)
              ((:ok :cache-hit) (refresh-handle-on-complete handle))
              (:skipped         (refresh-handle-on-skip handle))
              (:failed          (refresh-handle-on-fail handle)))))
    ;; Stats are updated under the scheduler's stats-lock, not the handle's.
    (case (refresh-completion-outcome completion)
      (:cache-hit (bump-stat scheduler :cache-hit))
      (:ok        (bump-stat scheduler :dispatched))
      (:skipped
       (bump-stat scheduler :skipped)
       (record-skip-reason
        scheduler
        (event-skip-reason-keyword (refresh-completion-event completion))))
      (:failed
       (bump-stat scheduler :failed)
       (record-failure-in-ring
        scheduler
        (failure-ring-entry completion handle))))
    (unregister-handle scheduler handle)
    (when callback
      (handler-case (funcall callback completion)
        (error (e)
          (log-error "Refresh completion callback for ~S errored: ~A"
                     (refresh-handle-id handle) e))))))

;;; ---------------------------------------------------------------------------
;;; Dispatch path — engine-backed submission
;;; ---------------------------------------------------------------------------

(defun build-completion-from-cache-hit (handle data etag tier enqueued-at)
  "Construct a refresh-completion for an immediate cache-hit short-circuit.

No HTTP was performed; HTTP-LATENCY is nil; DISPATCHED-AT is nil; OUTCOME is
:cache-hit (distinct from :ok so consumer code and the heat-map can treat the
\"no fetch needed\" case as the volatility signal it is)."
  (let ((now (get-universal-time)))
    (%make-refresh-completion
     :outcome :cache-hit
     :data data
     :etag etag
     :cache-tier tier
     :attempt-count 1
     :enqueued-at enqueued-at
     :dispatched-at nil
     :completed-at now
     :wait-time 0.0
     :rate-limit-wait 0.0
     :http-latency nil
     :endpoint (refresh-handle-endpoint handle)
     :operation-id (refresh-handle-operation-id handle)
     :batch-id (refresh-handle-batch-id handle))))

(defun build-completion-from-response (handle response start-time enqueued-at dispatched-at)
  "Construct a refresh-completion for a successful response."
  (let ((now (get-universal-time)))
    (%make-refresh-completion
     :outcome :ok
     :data (and response (esi-response-body response))
     :response response
     :etag (and response (esi-response-etag response))
     :attempt-count 1
     :enqueued-at enqueued-at
     :dispatched-at dispatched-at
     :completed-at now
     :wait-time (max 0.0 (float (- dispatched-at enqueued-at)))
     :rate-limit-wait 0.0
     :http-latency (max 0.0 (float (/ (- (get-internal-real-time) start-time)
                                      internal-time-units-per-second)))
     :endpoint (refresh-handle-endpoint handle)
     :operation-id (refresh-handle-operation-id handle)
     :batch-id (refresh-handle-batch-id handle))))

(defun build-failure-event (scheduler handle condition enqueued-at completed-at wait-time)
  "Construct an `esi-failure`-family condition instance describing the
underlying CONDITION raised by the engine.

The returned condition is delivered through `refresh-completion`'s `event`
slot. Mapping rules:

  esi-rate-limit-exceeded   → esi-rate-limit-exhausted
  esi-client-error          → esi-http-4xx-error
  esi-server-error          → esi-http-5xx-error
  everything else           → esi-network-failure (wrapping CONDITION as :cause)

The eve-gate.core ESI condition classes (`esi-not-found`, `esi-network-error`,
etc.) remain in use elsewhere in the system; the scheduler translates at its
boundary rather than altering those existing classes."
  (let ((common (list :scheduler scheduler
                      :handle handle
                      :operation-id (refresh-handle-operation-id handle)
                      :endpoint (refresh-handle-endpoint handle)
                      :batch-id (refresh-handle-batch-id handle)
                      :enqueued-at enqueued-at
                      :completed-at completed-at
                      :wait-time wait-time
                      :attempt-count 1)))
    (typecase condition
      (esi-rate-limit-exceeded
       (apply #'make-condition 'esi-rate-limit-exhausted
              :consecutive-420s 0
              :backoff-window-attempted 0
              common))
      (esi-client-error
       (apply #'make-condition 'esi-http-4xx-error
              :status (esi-error-status-code condition)
              :response-body (esi-error-response-body condition)
              :response-headers (esi-error-response-headers condition)
              common))
      (esi-server-error
       (apply #'make-condition 'esi-http-5xx-error
              :status (esi-error-status-code condition)
              :response-body (esi-error-response-body condition)
              :response-headers (esi-error-response-headers condition)
              common))
      (t
       (apply #'make-condition 'esi-network-failure
              :cause condition
              common)))))

(defun build-completion-from-failure (scheduler handle condition enqueued-at dispatched-at)
  "Construct a refresh-completion for a failed dispatch."
  (let* ((now (get-universal-time))
         (wait-time (max 0.0 (float (- (or dispatched-at enqueued-at) enqueued-at))))
         (event (build-failure-event scheduler handle condition
                                     enqueued-at now wait-time)))
    (%make-refresh-completion
     :outcome :failed
     :event event
     :attempt-count 1
     :enqueued-at enqueued-at
     :dispatched-at dispatched-at
     :completed-at now
     :wait-time wait-time
     :endpoint (refresh-handle-endpoint handle)
     :operation-id (refresh-handle-operation-id handle)
     :batch-id (refresh-handle-batch-id handle))))

(defun consult-cache-for-submission (scheduler endpoint query-pairs op-string)
  "Consult SCHEDULER's cache-manager for the cache key derived from ENDPOINT,
QUERY-PAIRS, and the request's auth context.

Returns one of:
  (:hit VALUE ETAG TIER)   — cache-fresh; caller short-circuits with a :cache-hit
                              completion. TIER is :l1 or :l2.
  :miss                    — no fresh cache entry; normal dispatch path.

Returns :miss when no cache-manager is configured.

Stale entries (no fresh value, but an ETag on file) are NOT handled here. The
cache middleware on the request pipeline reads the same cache during dispatch
and adds the `If-None-Match` header itself when it finds a stored ETag. Doing
that annotation at the scheduler level too would result in two competing
If-None-Match headers on the wire and ESI answering 400. The middleware is
the canonical site for conditional-request annotation; the scheduler's only
added value is the synchronous short-circuit on fresh entries before a token
is consumed."
  (let ((manager (request-scheduler-cache-manager scheduler)))
    (unless manager
      (return-from consult-cache-for-submission :miss))
    (let* ((auth-context (extract-auth-context-from-params query-pairs))
           (key (make-cache-key
                 endpoint
                 :params query-pairs
                 :auth-context auth-context
                 :datasource (cache-manager-default-datasource manager))))
      (multiple-value-bind (value etag tier)
          (cache-get manager key :operation-id op-string)
        (if value
            (list :hit value etag tier)
            :miss)))))

(defun dispatch-via-engine (scheduler handle method endpoint query-params)
  "Enqueue HANDLE's underlying request on the scheduler's engine.

The engine's completion callback delivers the refresh-completion. The
scheduler's in-flight counter is incremented at enqueue and decremented in
the callback regardless of outcome, so network failures that bypass response
middleware still release the slot.

ETag-conditional annotation (If-None-Match for stale-but-known entries) is
handled by the cache middleware on the request pipeline, not here. The
scheduler does not thread `:if-none-match` through — doing so would produce
two competing If-None-Match headers when a cache-manager is shared between
the scheduler and the http-client."
  (incf-in-flight scheduler)
  (let* ((enqueued-at (refresh-handle-enqueued-at handle))
         (engine-priority
           (cdr (assoc (refresh-handle-priority handle)
                       *scheduler-priority-map* :test #'eq)))
         (dispatch-time (get-universal-time))
         (start-internal (get-internal-real-time))
         (req (submit-request
               (request-scheduler-engine scheduler)
               endpoint
               :method method
               :priority engine-priority
               :params (list :query-params query-params)
               :callback
               (lambda (response)
                 (unwind-protect
                      (let ((completion
                              (build-completion-from-response
                               handle response start-internal
                               enqueued-at dispatch-time)))
                        (deliver-completion scheduler handle completion))
                   (decf-in-flight scheduler)))
               :error-callback
               (lambda (condition)
                 (unwind-protect
                      (let ((completion
                              (build-completion-from-failure
                               scheduler handle condition
                               enqueued-at dispatch-time)))
                        (deliver-completion scheduler handle completion))
                   (decf-in-flight scheduler)))
               :timeout 60)))
    (setf (slot-value handle 'queued-request) req
          (slot-value handle 'status) :dispatched)
    req))

;;; ---------------------------------------------------------------------------
;;; Public submission verbs
;;; ---------------------------------------------------------------------------

(defun submit-refresh (scheduler &key operation-id
                                       params
                                       priority
                                       deadline-seconds
                                       batch-id
                                       on-complete
                                       on-skip
                                       on-fail)
  "Submit a single refresh to SCHEDULER.

OPERATION-ID         (required) A string (\"get_markets_region_id_orders\") or a
                     symbol ('get-markets-region-id-orders). Symbols are
                     normalised to the canonical underscore form.
PARAMS               Plist of (:key value …) pairs covering both path and query
                     parameters. Path parameters are identified by matching
                     the endpoint template's {placeholder} names. Anything
                     not matched becomes a query parameter.
PRIORITY             REQUIRED. One of :critical :hot :warm :cold. Submitting
                     without :priority signals scheduler-missing-priority. Use
                     submit-bootstrap, not :bootstrap on submit-refresh, for
                     bulk drains.
DEADLINE-SECONDS     No-later-than dispatch deadline. Defaults per priority:
                     30 / 300 / 1800 / 21600 seconds for critical/hot/warm/cold.
BATCH-ID             Opaque string for grouping completions in observability.
ON-COMPLETE          (refresh-completion) → void, called for :ok and :cache-hit.
ON-SKIP              Called for :skipped (budget-exhausted, deadline-missed,
                     cancelled, queue-full).
ON-FAIL              Called for :failed (http-4xx/5xx/network/etc).

Returns a refresh-handle. The handle is opaque; query its status with
refresh-handle-status and its result with refresh-handle-completion."
  (ensure-scheduler-running scheduler operation-id)
  (let ((engine-priority (resolve-priority-or-error priority operation-id params)))
    (declare (ignore engine-priority))
    (multiple-value-bind (meta op-string) (resolve-endpoint-or-error operation-id)
      (let* ((path-template (getf meta :path))
             (method (or (getf meta :method) :get)))
        (multiple-value-bind (path-subs query-pairs)
            (split-path-and-query-params path-template params)
          (let* ((endpoint (substitute-path-parameters path-template path-subs))
                 (now (get-universal-time))
                 (deadline (or deadline-seconds (default-deadline-for priority)))
                 (handle (%make-refresh-handle
                          :scheduler scheduler
                          :operation-id (or op-string operation-id)
                          :endpoint endpoint
                          :priority priority
                          :deadline-at (+ now deadline)
                          :batch-id batch-id
                          :status :pending
                          :enqueued-at now
                          :on-complete on-complete
                          :on-skip on-skip
                          :on-fail on-fail)))
            (register-handle scheduler handle)
            (bump-stat scheduler :submitted)
            ;; Cache short-circuit: if the cache holds a still-fresh entry for
            ;; this (endpoint, params, auth) tuple, deliver a :cache-hit
            ;; completion immediately without consuming a rate-limit token.
            ;; Stale entries fall through to normal dispatch; the cache
            ;; middleware on the request pipeline handles ETag-conditional
            ;; annotation itself so we don't duplicate the If-None-Match
            ;; header.
            (let ((cache-result
                    (if (eq method :get)
                        (consult-cache-for-submission
                         scheduler endpoint query-pairs op-string)
                        :miss)))
              (cond
                ;; Cache fresh — synchronous short-circuit, no engine touch.
                ((and (consp cache-result) (eq (first cache-result) :hit))
                 (deliver-completion
                  scheduler handle
                  (build-completion-from-cache-hit
                   handle
                   (second cache-result)
                   (third cache-result)
                   (fourth cache-result)
                   now)))
                ;; Gate open (or priority :critical) — dispatch immediately.
                ((gate-open-for-priority-p scheduler priority)
                 (dispatch-via-engine scheduler handle method endpoint
                                      query-pairs))
                ;; Gate closed for non-critical — park on the held queue
                ;; for the dispatcher to revisit when budget recovers.
                (t
                 (hold-submission scheduler handle method endpoint query-pairs)))
              handle)))))))

(defun submit-refresh-batch (scheduler specs
                             &key batch-id on-progress on-batch-complete)
  "Submit a batch of refreshes. SPECS is a list of plists, each accepted by
submit-refresh's keyword args except that the per-spec :batch-id is overridden
by the outer BATCH-ID when supplied.

ON-PROGRESS is called as (completed total) on each completion; ON-BATCH-COMPLETE
is called once when every spec has settled.

Returns the list of refresh-handles in the same order as SPECS."
  (let* ((total (length specs))
         (completed-count 0)
         (counter-lock (bt:make-lock "submit-refresh-batch-progress-lock"))
         (effective-batch (or batch-id
                              (format nil "batch-~A" (gensym "BATCH-"))))
         (handles '()))
    (dolist (spec specs (nreverse handles))
      (let* ((spec-with-batch (append spec (list :batch-id effective-batch)))
             (wrap (lambda (orig-callback)
                     (lambda (completion)
                       (when orig-callback (funcall orig-callback completion))
                       (let ((done
                               (bt:with-lock-held (counter-lock)
                                 (incf completed-count))))
                         (when on-progress
                           (funcall on-progress done total))
                         (when (and on-batch-complete (= done total))
                           (funcall on-batch-complete))))))
             (with-wrap (copy-list spec-with-batch)))
        (setf (getf with-wrap :on-complete) (funcall wrap (getf with-wrap :on-complete))
              (getf with-wrap :on-skip)     (funcall wrap (getf with-wrap :on-skip))
              (getf with-wrap :on-fail)     (funcall wrap (getf with-wrap :on-fail)))
        (push (apply #'submit-refresh scheduler with-wrap) handles)))))
