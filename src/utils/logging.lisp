;;;; logging.lisp - Structured logging core for eve-gate
;;;;
;;;; Provides enterprise-grade structured logging with consistent JSON schema,
;;;; multiple log levels with filtering, contextual logging with request IDs
;;;; and correlation tracking, thread-safe concurrent logging, and high
;;;; performance with minimal overhead.
;;;;
;;;; Log levels (ordered by severity):
;;;;   TRACE - Finest-grained tracing (hot path, per-iteration)
;;;;   DEBUG - Development/diagnostic messages
;;;;   INFO  - Normal operational events
;;;;   WARN  - Degraded conditions (still functional)
;;;;   ERROR - Failure conditions requiring attention
;;;;   FATAL - Unrecoverable failures
;;;;
;;;; The logging system is designed around structured log entries that are
;;;; first-class data. Each entry carries a consistent schema of metadata
;;;; (timestamp, level, source, request-id, thread) plus a message and
;;;; optional structured fields. Entries flow through a pipeline:
;;;;
;;;;   (log-event) -> [filtering] -> [formatting] -> [output destinations]
;;;;
;;;; The output pipeline is pluggable: destinations (file, console, syslog)
;;;; are managed by log-output.lisp. This file provides the core entry
;;;; creation, filtering, and dispatch machinery.
;;;;
;;;; Thread safety: All mutable state (context bindings, configuration) is
;;;; either thread-local (via special variables) or protected by locks.
;;;; The log entry pipeline itself is lock-free until the final write.
;;;;
;;;; Performance: Level checks are inlined integer comparisons. When a level
;;;; is filtered out, zero allocation occurs. Context propagation uses
;;;; dynamic variables (thread-local, zero-cost to read).

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Log level definitions
;;; ---------------------------------------------------------------------------

(deftype log-level ()
  "Valid log level keywords, ordered from most to least verbose."
  '(member :trace :debug :info :warn :error :fatal))

(declaim (inline log-level-value))
(defun log-level-value (level)
  "Return the integer severity value for a log LEVEL keyword.
Higher values are more severe. Used for fast level comparison.

LEVEL: A log-level keyword

Returns an integer 0-5."
  (declare (type keyword level))
  (ecase level
    (:trace 0)
    (:debug 1)
    (:info  2)
    (:warn  3)
    (:error 4)
    (:fatal 5)))

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defparameter *log-level* :info
  "Current minimum log level. Messages below this severity are discarded.
Thread-safe: each thread can rebind via WITH-LOG-LEVEL.

Valid values: :TRACE :DEBUG :INFO :WARN :ERROR :FATAL")

(defparameter *log-source* nil
  "Current log source identifier (keyword or string).
Used to tag log entries with the originating subsystem.
Typically set via WITH-LOG-SOURCE or LET binding.

Example values: :http-client, :cache, :auth, :rate-limiter")

(defparameter *log-request-id* nil
  "Current request correlation ID (string).
Used to correlate all log entries for a single ESI request chain.
Set via WITH-REQUEST-CONTEXT or directly by middleware.")

(defparameter *log-correlation-id* nil
  "Higher-level correlation ID (string) for tracking operations spanning
multiple requests (e.g., bulk operations, paginated fetches).
Set via WITH-CORRELATION-CONTEXT.")

(defparameter *log-character-id* nil
  "Character ID associated with the current operation context.
Used for audit logging and per-character request attribution.")

(defparameter *log-extra-context* nil
  "Plist of additional context fields added to every log entry.
Set via WITH-LOG-CONTEXT. Merged into the structured entry fields.")

(defparameter *log-destinations* '()
  "List of active log destination functions.
Each destination is a function (log-entry) that writes the entry.
Managed by log-output.lisp. If empty, falls back to *standard-output*.")

(defparameter *log-destinations-lock* (bt:make-lock "log-destinations-lock")
  "Lock protecting *log-destinations* from concurrent modification.")

(defparameter *log-enabled-p* t
  "Master switch for logging. When NIL, all logging is suppressed.")

(defparameter *log-sequence-counter* 0
  "Monotonically increasing sequence number for log entries.
Used for ordering when timestamps have identical resolution.")

(defparameter *log-sequence-lock* (bt:make-lock "log-sequence-lock")
  "Lock protecting the sequence counter.")

;;; ---------------------------------------------------------------------------
;;; Log entry structure
;;; ---------------------------------------------------------------------------

(defstruct (log-entry (:constructor %make-log-entry))
  "A structured log entry carrying all context for a single log event.

Slots:
  TIMESTAMP: Universal time when the entry was created
  TIMESTAMP-INTERNAL: High-resolution internal time for sub-second precision
  LEVEL: Log level keyword (:trace through :fatal)
  SOURCE: Subsystem identifier keyword
  MESSAGE: Human-readable message string
  REQUEST-ID: Request correlation ID
  CORRELATION-ID: Operation-level correlation ID
  CHARACTER-ID: EVE character ID for attribution
  THREAD-NAME: Name of the thread that created the entry
  SEQUENCE: Monotonic sequence number for ordering
  FIELDS: Plist of additional structured data fields
  ERROR-P: Whether this entry represents an error condition"
  (timestamp (get-universal-time) :type integer)
  (timestamp-internal (get-internal-real-time) :type integer)
  (level :info :type keyword)
  (source nil :type (or null keyword string))
  (message "" :type string)
  (request-id nil :type (or null string))
  (correlation-id nil :type (or null string))
  (character-id nil :type (or null integer))
  (thread-name nil :type (or null string))
  (sequence 0 :type integer)
  (fields nil :type list)
  (error-p nil :type boolean))

(defun next-log-sequence ()
  "Return the next log sequence number. Thread-safe."
  (bt:with-lock-held (*log-sequence-lock*)
    (incf *log-sequence-counter*)))

(defun current-thread-name ()
  "Return the name of the current thread, or a fallback identifier."
  (or (bt:thread-name (bt:current-thread))
      "main"))

;;; ---------------------------------------------------------------------------
;;; Level checking (inlined for hot-path performance)
;;; ---------------------------------------------------------------------------

(declaim (inline log-level-active-p))
(defun log-level-active-p (level)
  "Check if logging at LEVEL would produce output given current *LOG-LEVEL*.
This is the fast-path gate: when it returns NIL, the caller should
skip all message formatting to avoid unnecessary allocation.

LEVEL: A log-level keyword
Returns T if the level is active."
  (and *log-enabled-p*
       (>= (log-level-value level)
            (log-level-value *log-level*))))

;;; ---------------------------------------------------------------------------
;;; Core logging dispatch
;;; ---------------------------------------------------------------------------

(defun make-log-entry (level message &key source fields error-p)
  "Create a structured log entry with full context.

LEVEL: Log level keyword
MESSAGE: Human-readable message string
SOURCE: Subsystem identifier (defaults to *log-source*)
FIELDS: Plist of additional structured fields
ERROR-P: Whether this entry represents an error

Returns a log-entry struct."
  (%make-log-entry
   :level level
   :message message
   :source (or source *log-source*)
   :request-id *log-request-id*
   :correlation-id *log-correlation-id*
   :character-id *log-character-id*
   :thread-name (current-thread-name)
   :sequence (next-log-sequence)
   :fields (if *log-extra-context*
               (append fields (copy-list *log-extra-context*))
               fields)
   :error-p error-p))

(defun dispatch-log-entry (entry)
  "Send a log entry to all registered destinations.
If no destinations are registered, falls back to simple console output.

ENTRY: A log-entry struct

Thread-safe: reads the destination list under lock."
  (let ((destinations (bt:with-lock-held (*log-destinations-lock*)
                        (copy-list *log-destinations*))))
    (if destinations
        (dolist (dest destinations)
          (handler-case
              (let ((fn (if (consp dest) (cdr dest) dest)))
                (funcall fn entry))
            (error (e)
              ;; Last-resort: write to *error-output* if a destination fails
              (format *error-output* "~&[LOG-DISPATCH-ERROR] ~A: ~A~%"
                      (type-of e) e))))
        ;; Fallback: simple console output when no destinations configured
        (format-log-entry-simple entry *standard-output*))))

(defun emit-log (level message &key source fields error-p)
  "Create and dispatch a log entry if the level is active.
This is the internal workhorse called by all logging functions.

LEVEL: Log level keyword
MESSAGE: Already-formatted message string
SOURCE: Subsystem identifier
FIELDS: Structured data plist
ERROR-P: Whether this is an error entry

Returns the log-entry if dispatched, NIL if filtered."
  (when (log-level-active-p level)
    (let ((entry (make-log-entry level message
                                 :source source
                                 :fields fields
                                 :error-p error-p)))
      (dispatch-log-entry entry)
      entry)))

;;; ---------------------------------------------------------------------------
;;; Public logging functions
;;; ---------------------------------------------------------------------------

(defun log-trace (format-string &rest args)
  "Log a TRACE-level message. For finest-grained operational tracing.

FORMAT-STRING: Format control string
ARGS: Format arguments"
  (when (log-level-active-p :trace)
    (emit-log :trace (apply #'format nil format-string args))))

(defun log-debug (format-string &rest args)
  "Log a DEBUG-level message. For development and diagnostic information.

FORMAT-STRING: Format control string
ARGS: Format arguments"
  (when (log-level-active-p :debug)
    (emit-log :debug (apply #'format nil format-string args))))

(defun log-info (format-string &rest args)
  "Log an INFO-level message. For normal operational events.

FORMAT-STRING: Format control string
ARGS: Format arguments"
  (when (log-level-active-p :info)
    (emit-log :info (apply #'format nil format-string args))))

(defun log-warn (format-string &rest args)
  "Log a WARN-level message. For degraded conditions that are still functional.

FORMAT-STRING: Format control string
ARGS: Format arguments"
  (when (log-level-active-p :warn)
    (emit-log :warn (apply #'format nil format-string args))))

(defun log-error (format-string &rest args)
  "Log an ERROR-level message. For failure conditions requiring attention.

FORMAT-STRING: Format control string
ARGS: Format arguments"
  (when (log-level-active-p :error)
    (emit-log :error (apply #'format nil format-string args)
              :error-p t)))

(defun log-fatal (format-string &rest args)
  "Log a FATAL-level message. For unrecoverable failures.

FORMAT-STRING: Format control string
ARGS: Format arguments"
  (when (log-level-active-p :fatal)
    (emit-log :fatal (apply #'format nil format-string args)
              :error-p t)))

;;; ---------------------------------------------------------------------------
;;; Structured logging (with explicit fields)
;;; ---------------------------------------------------------------------------

(defun log-event (level message &rest fields &key source &allow-other-keys)
  "Log a structured event with explicit key-value fields.
This is the preferred interface for machine-parseable logging.

LEVEL: Log level keyword
MESSAGE: Human-readable message string
SOURCE: Subsystem identifier keyword
FIELDS: Keyword plist of structured data

Returns the log-entry if dispatched, NIL if filtered.

Example:
  (log-event :info \"Request completed\"
             :source :http-client
             :endpoint \"/v5/characters/12345/\"
             :status 200
             :latency-ms 45.2
             :cache-hit nil)"
  (when (log-level-active-p level)
    ;; Strip :source from the fields plist since it's handled separately
    (let ((clean-fields (loop for (k v) on fields by #'cddr
                              unless (eq k :source)
                              append (list k v))))
      (emit-log level message
                :source source
                :fields clean-fields
                :error-p (>= (log-level-value level) (log-level-value :error))))))

;;; ---------------------------------------------------------------------------
;;; Context management macros
;;; ---------------------------------------------------------------------------

(defmacro with-log-level ((level) &body body)
  "Execute BODY with *LOG-LEVEL* bound to LEVEL.
Used to temporarily adjust logging verbosity.

LEVEL: A log-level keyword

Example:
  (with-log-level (:debug)
    (perform-complex-operation))"
  `(let ((*log-level* ,level))
     ,@body))

;; Keep backward compat: WITH-LOGGING is the old name
(defmacro with-logging ((level) &body body)
  "Execute body with specific logging level. Alias for WITH-LOG-LEVEL."
  `(with-log-level (,level) ,@body))

(defmacro with-log-source ((source) &body body)
  "Execute BODY with *LOG-SOURCE* bound to SOURCE.
All log entries created within BODY will be tagged with this source.

SOURCE: A keyword or string identifying the subsystem

Example:
  (with-log-source (:cache)
    (log-info \"Cache lookup for key ~A\" key))"
  `(let ((*log-source* ,source))
     ,@body))

(defmacro with-request-context ((&key request-id character-id) &body body)
  "Execute BODY with request correlation context.
All log entries within BODY will carry the given request-id and character-id.

REQUEST-ID: Unique string identifying this request chain
CHARACTER-ID: EVE character ID for attribution

Example:
  (with-request-context (:request-id (generate-request-id)
                         :character-id 12345)
    (http-request client path))"
  `(let ((*log-request-id* ,(or request-id `(generate-request-id)))
         ,@(when character-id
             `((*log-character-id* ,character-id))))
     ,@body))

(defmacro with-correlation-context ((correlation-id) &body body)
  "Execute BODY with a correlation ID for multi-request operations.
Useful for bulk operations, paginated fetches, and workflows.

CORRELATION-ID: String identifying the operation group

Example:
  (with-correlation-context ((format nil \"bulk-~A\" (generate-request-id)))
    (bulk-fetch-characters ids))"
  `(let ((*log-correlation-id* ,correlation-id))
     ,@body))

(defmacro with-log-context ((&rest fields) &body body)
  "Execute BODY with additional context fields in every log entry.
Fields are merged with any existing extra context.

FIELDS: Keyword plist of additional context

Example:
  (with-log-context (:endpoint \"/v5/characters/\" :method :get)
    (log-info \"Processing request\")
    (do-work))"
  `(let ((*log-extra-context*
           (append (list ,@fields) *log-extra-context*)))
     ,@body))

;;; ---------------------------------------------------------------------------
;;; Request ID generation
;;; ---------------------------------------------------------------------------

(defvar *request-id-counter* 0
  "Counter component for request ID generation.")

(defvar *request-id-lock* (bt:make-lock "request-id-lock")
  "Lock for request ID counter.")

(defun generate-request-id ()
  "Generate a unique request ID string.
Format: \"req-HHMMSS-NNNN\" where H/M/S are current time and N is a counter.
Designed to be human-readable in logs while remaining unique.

Returns a string."
  (let ((counter (bt:with-lock-held (*request-id-lock*)
                   (incf *request-id-counter*))))
    (multiple-value-bind (sec min hour)
        (decode-universal-time (get-universal-time))
      (format nil "req-~2,'0D~2,'0D~2,'0D-~4,'0D"
              hour min sec (mod counter 10000)))))

(defun generate-correlation-id (&optional prefix)
  "Generate a unique correlation ID string for multi-request operations.

PREFIX: Optional prefix string (default: \"corr\")

Returns a string."
  (let ((counter (bt:with-lock-held (*request-id-lock*)
                   (incf *request-id-counter*))))
    (format nil "~A-~A-~4,'0D"
            (or prefix "corr")
            (get-universal-time)
            (mod counter 10000))))

;;; ---------------------------------------------------------------------------
;;; Simple fallback formatter (used when no destinations configured)
;;; ---------------------------------------------------------------------------

(defun format-log-entry-simple (entry stream)
  "Format a log entry as a simple one-line text message.
Used as fallback when no log destinations are configured.

ENTRY: A log-entry struct
STREAM: Output stream"
  (multiple-value-bind (sec min hour)
      (decode-universal-time (log-entry-timestamp entry))
    (format stream "~&~2,'0D:~2,'0D:~2,'0D [~5A]~@[ ~A~]~@[ req=~A~] ~A~%"
            hour min sec
            (log-entry-level entry)
            (log-entry-source entry)
            (log-entry-request-id entry)
            (log-entry-message entry))))

;;; ---------------------------------------------------------------------------
;;; Log entry serialization (JSON)
;;; ---------------------------------------------------------------------------

(defun log-entry-to-plist (entry)
  "Convert a log-entry struct to a property list suitable for JSON serialization.

ENTRY: A log-entry struct

Returns a plist with string keys for JSON output."
  (let ((result (list :timestamp (format-log-timestamp
                                  (log-entry-timestamp entry)
                                  (log-entry-timestamp-internal entry))
                      :level (string-downcase (symbol-name (log-entry-level entry)))
                      :message (log-entry-message entry)
                      :sequence (log-entry-sequence entry)
                      :thread (log-entry-thread-name entry))))
    ;; Add optional fields only when present
    (when (log-entry-source entry)
      (setf result (list* :source
                          (if (keywordp (log-entry-source entry))
                              (string-downcase (symbol-name (log-entry-source entry)))
                              (log-entry-source entry))
                          result)))
    (when (log-entry-request-id entry)
      (setf result (list* :request-id (log-entry-request-id entry) result)))
    (when (log-entry-correlation-id entry)
      (setf result (list* :correlation-id (log-entry-correlation-id entry) result)))
    (when (log-entry-character-id entry)
      (setf result (list* :character-id (log-entry-character-id entry) result)))
    (when (log-entry-error-p entry)
      (setf result (list* :error t result)))
    ;; Merge structured fields
    (when (log-entry-fields entry)
      (loop for (k v) on (log-entry-fields entry) by #'cddr
            do (setf result (list* k v result))))
    result))

(defun format-log-timestamp (universal-time internal-time)
  "Format a log timestamp as ISO 8601 with sub-second precision.

UNIVERSAL-TIME: CL universal time (seconds since epoch)
INTERNAL-TIME: GET-INTERNAL-REAL-TIME value for sub-second component

Returns a string like \"2026-04-13T15:30:45.123Z\"."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time universal-time 0)
    (let ((sub-second (mod internal-time internal-time-units-per-second)))
      (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0D.~3,'0DZ"
              year month day hour min sec
              (floor (* 1000 sub-second) internal-time-units-per-second)))))

;;; ---------------------------------------------------------------------------
;;; Log destination management
;;; ---------------------------------------------------------------------------

(defun add-log-destination (destination &key (name nil))
  "Register a log destination function.

DESTINATION: Function (log-entry) -> void that writes the entry
NAME: Optional keyword name for later removal

Returns the updated destination list."
  (bt:with-lock-held (*log-destinations-lock*)
    (let ((entry (cons name destination)))
      ;; Replace existing destination with same name
      (when name
        (setf *log-destinations*
              (remove name *log-destinations*
                      :key (lambda (d) (when (consp d) (car d))))))
      (push entry *log-destinations*))
    *log-destinations*))

(defun remove-log-destination (name)
  "Remove a named log destination.

NAME: The keyword name given when the destination was added

Returns the updated destination list."
  (bt:with-lock-held (*log-destinations-lock*)
    (setf *log-destinations*
          (remove name *log-destinations*
                  :key (lambda (d) (when (consp d) (car d)))))
    *log-destinations*))

(defun clear-log-destinations ()
  "Remove all registered log destinations.
After this, logging falls back to simple console output."
  (bt:with-lock-held (*log-destinations-lock*)
    (setf *log-destinations* '())))

(defun list-log-destinations ()
  "Return a list of registered log destination names."
  (bt:with-lock-held (*log-destinations-lock*)
    (mapcar (lambda (d) (if (consp d) (car d) :anonymous))
            *log-destinations*)))

;;; ---------------------------------------------------------------------------
;;; Initialization
;;; ---------------------------------------------------------------------------

(defun initialize-logging (&key (level :info) (enable t))
  "Initialize the logging subsystem with default configuration.

LEVEL: Initial log level (default: :info)
ENABLE: Whether logging is enabled (default: T)

Returns T."
  (setf *log-level* level
        *log-enabled-p* enable
        *log-sequence-counter* 0
        *request-id-counter* 0)
  (log-info "Logging initialized at level ~A" level)
  t)

;;; ---------------------------------------------------------------------------
;;; REPL inspection utilities
;;; ---------------------------------------------------------------------------

(defun log-level-name (level)
  "Return the display name for a log level keyword."
  (string-upcase (symbol-name level)))

(defun logging-status (&optional (stream *standard-output*))
  "Print the current logging configuration to STREAM.
Useful for REPL inspection."
  (format stream "~&=== Logging Configuration ===~%")
  (format stream "  Enabled:        ~A~%" *log-enabled-p*)
  (format stream "  Level:          ~A~%" *log-level*)
  (format stream "  Source:         ~A~%" (or *log-source* "(none)"))
  (format stream "  Request ID:     ~A~%" (or *log-request-id* "(none)"))
  (format stream "  Correlation ID: ~A~%" (or *log-correlation-id* "(none)"))
  (format stream "  Character ID:   ~A~%" (or *log-character-id* "(none)"))
  (format stream "  Destinations:   ~A~%" (list-log-destinations))
  (format stream "  Sequence:       ~D~%" *log-sequence-counter*)
  (format stream "=== End Logging Config ===~%")
  (values))
