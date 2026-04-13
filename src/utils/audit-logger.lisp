;;;; audit-logger.lisp - Audit and compliance logging for eve-gate
;;;;
;;;; Provides audit trail logging for enterprise EVE Online ESI API usage.
;;;; Audit events are distinct from operational logs: they record WHO did
;;;; WHAT, WHEN, and the OUTCOME — forming a compliance-ready audit trail.
;;;;
;;;; Audit categories:
;;;;   - Character authentication events (login, logout, token lifecycle)
;;;;   - ESI endpoint access patterns (who accessed what data)
;;;;   - Data export and privacy compliance
;;;;   - Rate limit violations and error patterns
;;;;   - Security-relevant events (scope changes, unauthorized access)
;;;;
;;;; Audit entries are always logged at INFO level or above (never filtered
;;;; by the standard log level) and carry a distinct :audit source tag.
;;;; They can be routed to a separate audit log file via log destinations.
;;;;
;;;; Privacy: Character names and identifiers are logged for accountability.
;;;; Response data is NOT included in audit logs — only metadata about
;;;; what was accessed. Token values are never logged.
;;;;
;;;; Thread safety: All functions are thread-safe. The audit ring buffer
;;;; provides bounded memory usage for the in-memory audit trail.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Audit configuration
;;; ---------------------------------------------------------------------------

(defparameter *audit-enabled-p* t
  "Master switch for audit logging. When NIL, audit events are suppressed.")

(defparameter *audit-retention-count* 1000
  "Maximum number of audit entries retained in the in-memory ring buffer.")

;;; ---------------------------------------------------------------------------
;;; Audit entry structure
;;; ---------------------------------------------------------------------------

(defstruct (audit-entry (:constructor %make-audit-entry))
  "A single audit trail entry recording a security/compliance-relevant event.

Slots:
  TIMESTAMP: Universal time of the event
  EVENT-TYPE: Keyword classifying the event (e.g., :access, :auth, :export)
  ACTION: Specific action keyword (e.g., :endpoint-access, :token-refresh)
  CHARACTER-ID: EVE character ID performing the action (NIL for system events)
  CHARACTER-NAME: EVE character name (when available)
  ENDPOINT: ESI endpoint accessed (for access events)
  METHOD: HTTP method used
  STATUS: Outcome status (:success, :denied, :error)
  DETAILS: Plist of additional structured context
  REQUEST-ID: Correlation request ID
  IP-ADDRESS: Client IP address (when available, for web-facing usage)"
  (timestamp (get-universal-time) :type integer)
  (event-type :access :type keyword)
  (action :unknown :type keyword)
  (character-id nil :type (or null integer))
  (character-name nil :type (or null string))
  (endpoint nil :type (or null string))
  (method nil :type (or null keyword))
  (status :success :type keyword)
  (details nil :type list)
  (request-id nil :type (or null string))
  (ip-address nil :type (or null string)))

;;; ---------------------------------------------------------------------------
;;; Audit trail ring buffer
;;; ---------------------------------------------------------------------------

(defstruct (audit-trail (:constructor %make-audit-trail))
  "Bounded in-memory ring buffer of audit entries.

Slots:
  LOCK: Mutex for thread-safe access
  ENTRIES: Vector ring buffer of audit-entry structs
  SIZE: Capacity of the ring buffer
  HEAD: Write position
  COUNT: Number of entries in the buffer
  TOTAL-COUNT: Total entries ever recorded"
  (lock (bt:make-lock "audit-trail-lock"))
  (entries nil :type (or null simple-vector))
  (size 1000 :type fixnum)
  (head 0 :type fixnum)
  (count 0 :type fixnum)
  (total-count 0 :type integer))

(defvar *audit-trail* nil
  "Global audit trail instance. Initialize with INITIALIZE-AUDIT-LOGGING.")

(defun initialize-audit-logging (&key (retention-count *audit-retention-count*))
  "Initialize or reset the audit logging subsystem.

RETENTION-COUNT: Maximum in-memory audit entries to retain

Returns the audit trail instance."
  (setf *audit-trail*
        (%make-audit-trail
         :entries (make-array retention-count :initial-element nil)
         :size retention-count))
  *audit-trail*)

(defun ensure-audit-trail ()
  "Ensure the audit trail is initialized. Returns the instance."
  (or *audit-trail*
      (initialize-audit-logging)))

(defun record-audit-entry (entry)
  "Record an audit entry in the ring buffer and dispatch to log destinations.

ENTRY: An audit-entry struct

Thread-safe."
  (let ((trail (ensure-audit-trail)))
    ;; Store in ring buffer
    (bt:with-lock-held ((audit-trail-lock trail))
      (let ((head (audit-trail-head trail))
            (size (audit-trail-size trail)))
        (setf (svref (audit-trail-entries trail) head) entry)
        (setf (audit-trail-head trail) (mod (1+ head) size))
        (when (< (audit-trail-count trail) size)
          (incf (audit-trail-count trail)))
        (incf (audit-trail-total-count trail))))
    ;; Also emit as a structured log event (always at INFO or above)
    (emit-audit-log-event entry)
    entry))

(defun emit-audit-log-event (entry)
  "Emit an audit entry through the standard logging system.
Audit events are always emitted at :info level regardless of *log-level*
to ensure they are never silently dropped."
  (let ((fields (list :event-type (string-downcase
                                   (symbol-name (audit-entry-event-type entry)))
                      :action (string-downcase
                               (symbol-name (audit-entry-action entry)))
                      :audit t
                      :status (string-downcase
                               (symbol-name (audit-entry-status entry))))))
    ;; Add optional fields
    (when (audit-entry-character-id entry)
      (setf fields (list* :character-id (audit-entry-character-id entry) fields)))
    (when (audit-entry-character-name entry)
      (setf fields (list* :character-name (audit-entry-character-name entry) fields)))
    (when (audit-entry-endpoint entry)
      (setf fields (list* :endpoint (audit-entry-endpoint entry) fields)))
    (when (audit-entry-method entry)
      (setf fields (list* :method (string-downcase
                                   (symbol-name (audit-entry-method entry)))
                          fields)))
    (when (audit-entry-ip-address entry)
      (setf fields (list* :ip-address (audit-entry-ip-address entry) fields)))
    ;; Merge details
    (loop for (k v) on (audit-entry-details entry) by #'cddr
          do (setf fields (list* k v fields)))
    ;; Emit at INFO level with :audit source
    (apply #'log-event :info
           (format nil "AUDIT: ~A ~A ~A~@[ ~A~] => ~A"
                   (audit-entry-event-type entry)
                   (audit-entry-action entry)
                   (or (audit-entry-character-name entry)
                       (audit-entry-character-id entry)
                       "system")
                   (audit-entry-endpoint entry)
                   (audit-entry-status entry))
           :source :audit
           fields)))

;;; ---------------------------------------------------------------------------
;;; Audit logging API — Authentication events
;;; ---------------------------------------------------------------------------

(defun audit-authentication (action character-id &key character-name
                                                       status
                                                       scopes
                                                       error-message)
  "Record an authentication audit event.

ACTION: One of :login, :logout, :token-refresh, :token-expired, :token-revoked
CHARACTER-ID: EVE character ID
CHARACTER-NAME: EVE character name
STATUS: :success or :failed
SCOPES: List of OAuth scopes involved
ERROR-MESSAGE: Error description for failed events"
  (when *audit-enabled-p*
    (record-audit-entry
     (%make-audit-entry
      :event-type :auth
      :action action
      :character-id character-id
      :character-name character-name
      :status (or status :success)
      :request-id *log-request-id*
      :details (append
                (when scopes
                  (list :scopes-count (length scopes)))
                (when error-message
                  (list :error-message error-message)))))))

;;; ---------------------------------------------------------------------------
;;; Audit logging API — Endpoint access events
;;; ---------------------------------------------------------------------------

(defun audit-endpoint-access (method endpoint &key character-id
                                                    character-name
                                                    status-code
                                                    scopes-used
                                                    cached-p)
  "Record an ESI endpoint access audit event.

METHOD: HTTP method keyword
ENDPOINT: ESI endpoint path
CHARACTER-ID: Character performing the access
CHARACTER-NAME: Character name
STATUS-CODE: HTTP response status code
SCOPES-USED: OAuth scopes required for this endpoint
CACHED-P: Whether the response was served from cache"
  (when *audit-enabled-p*
    (let ((status (cond
                    ((null status-code) :unknown)
                    ((< status-code 400) :success)
                    ((< status-code 500) :denied)
                    (t :error))))
      (record-audit-entry
       (%make-audit-entry
        :event-type :access
        :action :endpoint-access
        :character-id character-id
        :character-name character-name
        :endpoint endpoint
        :method method
        :status status
        :request-id *log-request-id*
        :details (append
                  (when status-code
                    (list :status-code status-code))
                  (when scopes-used
                    (list :scopes-count (length scopes-used)))
                  (when cached-p
                    (list :cached t))))))))

;;; ---------------------------------------------------------------------------
;;; Audit logging API — Data export and privacy
;;; ---------------------------------------------------------------------------

(defun audit-data-export (character-id data-type &key record-count
                                                       destination
                                                       format)
  "Record a data export audit event for privacy compliance.

CHARACTER-ID: Character whose data is being exported
DATA-TYPE: Type of data exported (keyword, e.g., :assets, :wallet, :contacts)
RECORD-COUNT: Number of records exported
DESTINATION: Where the data is going (keyword, e.g., :file, :api, :display)
FORMAT: Export format (keyword, e.g., :json, :csv)"
  (when *audit-enabled-p*
    (record-audit-entry
     (%make-audit-entry
      :event-type :data-export
      :action :export
      :character-id character-id
      :status :success
      :request-id *log-request-id*
      :details (list :data-type (string-downcase (symbol-name data-type))
                     :record-count record-count
                     :destination (when destination
                                    (string-downcase (symbol-name destination)))
                     :format (when format
                               (string-downcase (symbol-name format))))))))

;;; ---------------------------------------------------------------------------
;;; Audit logging API — Rate limit and error events
;;; ---------------------------------------------------------------------------

(defun audit-rate-limit-violation (character-id endpoint &key
                                                              error-limit-remain
                                                              retry-after)
  "Record a rate limit violation audit event.

CHARACTER-ID: Character that triggered the violation
ENDPOINT: The rate-limited endpoint
ERROR-LIMIT-REMAIN: ESI error budget remaining
RETRY-AFTER: Seconds until retry is allowed"
  (when *audit-enabled-p*
    (record-audit-entry
     (%make-audit-entry
      :event-type :rate-limit
      :action :violation
      :character-id character-id
      :endpoint endpoint
      :status :denied
      :request-id *log-request-id*
      :details (list :error-limit-remain error-limit-remain
                     :retry-after retry-after)))))

(defun audit-security-event (action &key character-id character-name
                                         endpoint details status)
  "Record a security-relevant audit event.

ACTION: Security event type (e.g., :unauthorized-access, :scope-violation,
        :token-abuse, :suspicious-pattern)
CHARACTER-ID: Character involved
CHARACTER-NAME: Character name
ENDPOINT: Related endpoint
DETAILS: Additional context plist
STATUS: Event outcome"
  (when *audit-enabled-p*
    (record-audit-entry
     (%make-audit-entry
      :event-type :security
      :action action
      :character-id character-id
      :character-name character-name
      :endpoint endpoint
      :status (or status :flagged)
      :request-id *log-request-id*
      :details details))))

;;; ---------------------------------------------------------------------------
;;; Audit trail querying
;;; ---------------------------------------------------------------------------

(defun query-audit-trail (&key event-type action character-id
                                status (limit 50)
                                (trail *audit-trail*))
  "Query the in-memory audit trail with optional filters.

EVENT-TYPE: Filter by event type keyword
ACTION: Filter by action keyword
CHARACTER-ID: Filter by character ID
STATUS: Filter by outcome status
LIMIT: Maximum entries to return (default: 50)
TRAIL: Audit trail to query (default: *audit-trail*)

Returns a list of matching audit-entry structs, newest first."
  (unless trail
    (return-from query-audit-trail nil))
  (bt:with-lock-held ((audit-trail-lock trail))
    (let ((entries '())
          (size (audit-trail-size trail))
          (count (audit-trail-count trail))
          (head (audit-trail-head trail)))
      ;; Iterate backward from most recent
      (loop for i from 1 to count
            for idx = (mod (- head i) size)
            for entry = (svref (audit-trail-entries trail) idx)
            while (< (length entries) limit)
            when (and entry
                      (or (null event-type)
                          (eq event-type (audit-entry-event-type entry)))
                      (or (null action)
                          (eq action (audit-entry-action entry)))
                      (or (null character-id)
                          (eql character-id (audit-entry-character-id entry)))
                      (or (null status)
                          (eq status (audit-entry-status entry))))
            do (push entry entries))
      (nreverse entries))))

(defun audit-trail-summary (&key (trail *audit-trail*)
                                  (stream *standard-output*))
  "Print a summary of the audit trail to STREAM.

TRAIL: Audit trail to summarize
STREAM: Output stream"
  (unless trail
    (format stream "~&Audit trail not initialized.~%")
    (return-from audit-trail-summary nil))
  (bt:with-lock-held ((audit-trail-lock trail))
    (format stream "~&=== Audit Trail Summary ===~%")
    (format stream "  Total events:    ~D~%" (audit-trail-total-count trail))
    (format stream "  Retained:        ~D / ~D~%"
            (audit-trail-count trail)
            (audit-trail-size trail))
    ;; Count by event type
    (let ((type-counts (make-hash-table :test 'eq)))
      (loop for i from 0 below (audit-trail-count trail)
            for idx = (mod (- (audit-trail-head trail) 1 i)
                          (audit-trail-size trail))
            for entry = (svref (audit-trail-entries trail) idx)
            when entry
            do (incf (gethash (audit-entry-event-type entry) type-counts 0)))
      (format stream "~%  By event type:~%")
      (maphash (lambda (k v)
                 (format stream "    ~A: ~D~%" k v))
               type-counts))
    ;; Count by status
    (let ((status-counts (make-hash-table :test 'eq)))
      (loop for i from 0 below (audit-trail-count trail)
            for idx = (mod (- (audit-trail-head trail) 1 i)
                          (audit-trail-size trail))
            for entry = (svref (audit-trail-entries trail) idx)
            when entry
            do (incf (gethash (audit-entry-status entry) status-counts 0)))
      (format stream "~%  By status:~%")
      (maphash (lambda (k v)
                 (format stream "    ~A: ~D~%" k v))
               status-counts))
    (format stream "=== End Audit Summary ===~%"))
  trail)

(defun format-audit-entry (entry &optional (stream *standard-output*))
  "Format a single audit entry for human-readable display.

ENTRY: An audit-entry struct
STREAM: Output stream"
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (audit-entry-timestamp entry) 0)
    (format stream "~&~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D "
            year month day hour min sec))
  (format stream "[~A] ~A ~A"
          (audit-entry-event-type entry)
          (audit-entry-action entry)
          (or (audit-entry-character-name entry)
              (audit-entry-character-id entry)
              "system"))
  (when (audit-entry-endpoint entry)
    (format stream " ~A ~A"
            (or (audit-entry-method entry) "")
            (audit-entry-endpoint entry)))
  (format stream " => ~A" (audit-entry-status entry))
  (when (audit-entry-details entry)
    (format stream " ~{~A=~A~^, ~}" (audit-entry-details entry)))
  (terpri stream))

(defun show-recent-audit-events (&key (count 20) event-type character-id)
  "Display recent audit events at the REPL.

COUNT: Number of events to show (default: 20)
EVENT-TYPE: Optional filter by event type
CHARACTER-ID: Optional filter by character"
  (let ((events (query-audit-trail :event-type event-type
                                   :character-id character-id
                                   :limit count)))
    (if events
        (progn
          (format t "~&Showing ~D recent audit events:~%~%" (length events))
          (dolist (entry events)
            (format-audit-entry entry)))
        (format t "~&No matching audit events found.~%")))
  (values))
