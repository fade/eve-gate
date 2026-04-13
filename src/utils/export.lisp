;;;; export.lisp - Data export system for eve-gate
;;;;
;;;; Provides comprehensive data export functionality for EVE Online ESI data.
;;;; Supports multiple formats (JSON, CSV, EDN, SEXP), privacy controls via
;;;; the data-privacy module, incremental and full export modes, and streaming
;;;; output for large datasets.
;;;;
;;;; Export workflow:
;;;;   1. Create an export-job describing what to export
;;;;   2. Optionally apply privacy controls (anonymization, field filtering)
;;;;   3. Apply retention policy enforcement
;;;;   4. Encode data in the requested format
;;;;   5. Write to file or stream with optional compression metadata
;;;;   6. Record audit trail entry
;;;;
;;;; Thread safety: Export jobs are independent; concurrent exports are safe.
;;;; Shared state (audit trail) is protected by locks in the respective modules.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Export job definition
;;; ---------------------------------------------------------------------------

(defstruct (export-job (:constructor %make-export-job))
  "Describes a data export operation.

Slots:
  ID: Unique job identifier
  NAME: Human-readable export name
  FORMAT: Output format keyword (:json, :csv, :edn, :sexp)
  DATA-CATEGORY: ESI data category being exported
  CHARACTER-ID: Character whose data is exported (NIL for aggregate)
  RECORDS: The data records to export (list of plists)
  DESTINATION: Output path or :stream for stream output
  STATUS: Job status (:pending, :running, :completed, :failed)
  CREATED-AT: Creation timestamp
  COMPLETED-AT: Completion timestamp
  RECORD-COUNT: Number of records exported
  OPTIONS: Plist of additional options
  ERROR-MESSAGE: Error description on failure"
  (id (gensym "EXPORT-") :type symbol)
  (name "" :type string)
  (format :json :type keyword)
  (data-category :unknown :type keyword)
  (character-id nil :type (or null integer))
  (records nil :type list)
  (destination nil :type (or null string pathname))
  (status :pending :type keyword)
  (created-at (get-universal-time) :type integer)
  (completed-at 0 :type integer)
  (record-count 0 :type integer)
  (options nil :type list)
  (error-message nil :type (or null string)))

(defun make-export-job (name records &key (format :json)
                                           (data-category :unknown)
                                           character-id
                                           destination
                                           options)
  "Create a new export job.

NAME: Human-readable export name
RECORDS: Data to export (list of plists, hash-tables, or vectors)
FORMAT: Output format (default: :json)
DATA-CATEGORY: ESI data category for privacy classification
CHARACTER-ID: Character ID if character-specific data
DESTINATION: File path for output (NIL for in-memory)
OPTIONS: Plist of options:
  :pretty - Pretty-print output (default: NIL)
  :anonymize - Apply anonymization (default: NIL)
  :anonymize-strategy - :pseudonymize, :remove, :mask (default: :pseudonymize)
  :enforce-retention - Apply retention policy (default: T)
  :include-metadata - Include export metadata header (default: T)
  :fields - List of fields to include (NIL = all)
  :exclude-fields - List of fields to exclude
  :filter-fn - Predicate function to filter records
  :sort-by - Field keyword to sort by
  :sort-order - :ascending or :descending (default: :ascending)

Returns an export-job struct."
  (%make-export-job
   :name name
   :records (ensure-list-of-plists records)
   :format format
   :data-category data-category
   :character-id character-id
   :destination destination
   :record-count (length (ensure-list-of-plists records))
   :options options))

;;; ---------------------------------------------------------------------------
;;; Export execution
;;; ---------------------------------------------------------------------------

(defun execute-export (job)
  "Execute an export job, writing data to the destination.

JOB: An export-job struct

Returns (VALUES job output-or-path) where output-or-path is either
the encoded string (if no destination) or the file path written to.

Side effects:
  - Writes file if destination is set
  - Records audit trail entry
  - Updates job status"
  (handler-case
      (progn
        (setf (export-job-status job) :running)
        (let* ((records (prepare-export-records job))
               (export-data (build-export-payload job records))
               (result (write-export-output job export-data)))
          (setf (export-job-status job) :completed
                (export-job-completed-at job) (get-universal-time)
                (export-job-record-count job) (length records))
          ;; Audit logging
          (audit-export-operation job)
          (values job result)))
    (error (e)
      (setf (export-job-status job) :failed
            (export-job-error-message job) (princ-to-string e))
      (log-error "Export failed: ~A (job: ~A)" e (export-job-name job))
      (values job nil))))

(defun prepare-export-records (job)
  "Prepare records for export by applying filters, privacy controls, and sorting.

JOB: An export-job struct

Returns a processed list of plists."
  (let* ((records (export-job-records job))
         (options (export-job-options job))
         (data-category (export-job-data-category job)))
    ;; Apply custom filter
    (when-let ((filter-fn (getf options :filter-fn)))
      (setf records (remove-if-not filter-fn records)))
    ;; Apply field selection
    (when-let ((fields (getf options :fields)))
      (setf records (mapcar (lambda (r) (select-fields r fields)) records)))
    ;; Apply field exclusion
    (when-let ((exclude (getf options :exclude-fields)))
      (setf records (mapcar (lambda (r) (exclude-fields r exclude)) records)))
    ;; Apply retention policy enforcement
    (when (getf options :enforce-retention t)
      (setf records (enforce-retention records data-category)))
    ;; Apply anonymization
    (when (getf options :anonymize)
      (let ((strategy (or (getf options :anonymize-strategy) :pseudonymize)))
        (setf records (anonymize-dataset records :strategy strategy))))
    ;; Apply sorting
    (when-let ((sort-field (getf options :sort-by)))
      (let ((order (or (getf options :sort-order) :ascending)))
        (setf records (sort-records records sort-field order))))
    records))

(defun select-fields (record fields)
  "Return a new plist containing only the specified FIELDS from RECORD."
  (let ((result '()))
    (dolist (field fields)
      (let ((value (getf record field)))
        (when value
          (setf (getf result field) value))))
    result))

(defun exclude-fields (record exclude-list)
  "Return a new plist with EXCLUDE-LIST fields removed from RECORD."
  (let ((result '()))
    (loop for (key value) on record by #'cddr
          unless (member key exclude-list)
          do (setf (getf result key) value))
    result))

(defun sort-records (records field order)
  "Sort RECORDS by FIELD in ORDER (:ascending or :descending)."
  (let ((sorted (sort (copy-list records)
                      (lambda (a b)
                        (let ((va (getf a field))
                              (vb (getf b field)))
                          (when (and va vb)
                            (typecase va
                              (number (< va vb))
                              (string (string< va vb))
                              (t nil))))))))
    (if (eq order :descending)
        (nreverse sorted)
        sorted)))

;;; ---------------------------------------------------------------------------
;;; Export payload construction
;;; ---------------------------------------------------------------------------

(defun build-export-payload (job records)
  "Build the complete export payload including optional metadata.

JOB: The export job
RECORDS: Processed records

Returns the data structure to be encoded."
  (if (getf (export-job-options job) :include-metadata t)
      (list :metadata (build-export-metadata job records)
            :data records)
      records))

(defun build-export-metadata (job records)
  "Build metadata for an export payload."
  (list :export-name (export-job-name job)
        :export-id (symbol-name (export-job-id job))
        :format (export-job-format job)
        :data-category (export-job-data-category job)
        :record-count (length records)
        :exported-at (format-export-timestamp (get-universal-time))
        :eve-gate-version "0.1.0"
        :privacy-classification (classify-data (export-job-data-category job))
        :anonymized (if (getf (export-job-options job) :anonymize) t nil)))

(defun format-export-timestamp (universal-time)
  "Format a universal-time as ISO 8601 for export metadata."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time universal-time 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour min sec)))

;;; ---------------------------------------------------------------------------
;;; Export output writing
;;; ---------------------------------------------------------------------------

(defun write-export-output (job data)
  "Write export data to the job's destination.

JOB: The export job
DATA: The payload to encode

Returns the encoded string (if no destination) or the file path."
  (let ((format (export-job-format job))
        (destination (export-job-destination job))
        (pretty (getf (export-job-options job) :pretty)))
    (if destination
        (progn
          (ensure-directories-exist destination)
          (with-open-file (stream destination
                                  :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create
                                  :external-format :utf-8)
            (encode-data data format stream :pretty pretty))
          (log-info "Export written to ~A (~D records)"
                    destination (export-job-record-count job))
          (namestring destination))
        ;; In-memory: return string
        (encode-to-string data format :pretty pretty))))

;;; ---------------------------------------------------------------------------
;;; Audit integration
;;; ---------------------------------------------------------------------------

(defun audit-export-operation (job)
  "Record an audit entry for a completed export operation."
  (when *audit-enabled-p*
    (audit-data-export
     (or (export-job-character-id job) 0)
     (export-job-data-category job)
     :record-count (export-job-record-count job)
     :destination (if (export-job-destination job) :file :memory)
     :format (export-job-format job))))

;;; ---------------------------------------------------------------------------
;;; High-level export functions
;;; ---------------------------------------------------------------------------

(defun export-character-data (character-id data-category records
                              &key (format :json) destination
                                   (anonymize nil) (pretty nil))
  "Export character-specific ESI data with privacy controls.

CHARACTER-ID: EVE character ID
DATA-CATEGORY: ESI data category keyword
RECORDS: Data to export
FORMAT: Output format (default: :json)
DESTINATION: File path (NIL for string output)
ANONYMIZE: Whether to anonymize personal data
PRETTY: Pretty-print output

Returns (VALUES export-job result-string-or-path)."
  (with-privacy-controls (data-category character-id :audit t)
    (let ((job (make-export-job
                (format nil "~A export for character ~A" data-category character-id)
                records
                :format format
                :data-category data-category
                :character-id character-id
                :destination destination
                :options (list :pretty pretty
                               :anonymize anonymize
                               :enforce-retention t
                               :include-metadata t))))
      (execute-export job))))

(defun export-market-data (records &key (format :json) destination
                                         region-id type-id
                                         (pretty nil))
  "Export market data with time-series support.

RECORDS: Market data records
FORMAT: Output format (default: :json)
DESTINATION: File path (NIL for string output)
REGION-ID: Optional region filter
TYPE-ID: Optional item type filter
PRETTY: Pretty-print output

Returns (VALUES export-job result)."
  (let ((filtered records))
    (when region-id
      (setf filtered (remove-if-not
                      (lambda (r) (eql (getf r :region-id) region-id))
                      filtered)))
    (when type-id
      (setf filtered (remove-if-not
                      (lambda (r) (eql (getf r :type-id) type-id))
                      filtered)))
    (let ((job (make-export-job
                "Market data export"
                filtered
                :format format
                :data-category :market-history
                :destination destination
                :options (list :pretty pretty
                               :enforce-retention nil
                               :include-metadata t
                               :sort-by :date
                               :sort-order :descending))))
      (execute-export job))))

(defun export-corporation-data (corporation-id data-category records
                                &key (format :json) destination
                                     (anonymize-members nil))
  "Export corporation-level data with optional member anonymization.

CORPORATION-ID: The corporation ID
DATA-CATEGORY: Data category keyword
RECORDS: Corporation data records
FORMAT: Output format
DESTINATION: File path
ANONYMIZE-MEMBERS: Whether to anonymize member character data

Returns (VALUES export-job result)."
  (let ((job (make-export-job
              (format nil "Corporation ~A ~A export" corporation-id data-category)
              records
              :format format
              :data-category data-category
              :destination destination
              :options (list :anonymize anonymize-members
                             :enforce-retention t
                             :include-metadata t))))
    (execute-export job)))

(defun export-for-portability (character-id records-by-category
                               &key (format :json) destination)
  "Export all data for a character as a GDPR data portability package.

CHARACTER-ID: The data subject's character ID
RECORDS-BY-CATEGORY: Plist mapping data-category keywords to record lists
DESTINATION: Output directory path

Returns (VALUES export-jobs result-paths)."
  (let ((jobs '())
        (results '()))
    ;; Create portability request record
    (create-portability-request character-id :format format)
    ;; Export each category
    (loop for (category records) on records-by-category by #'cddr
          for filename = (format nil "~A-~A.~A"
                                 character-id
                                 (string-downcase (symbol-name category))
                                 (format-extension format))
          for path = (when destination
                       (merge-pathnames filename (pathname destination)))
          do (multiple-value-bind (job result)
                 (export-character-data character-id category records
                                        :format format
                                        :destination path
                                        :anonymize nil
                                        :pretty t)
               (push job jobs)
               (push result results)))
    (values (nreverse jobs) (nreverse results))))

;;; ---------------------------------------------------------------------------
;;; Incremental export support
;;; ---------------------------------------------------------------------------

(defstruct (export-checkpoint (:constructor make-export-checkpoint))
  "Tracks the state of an incremental export for resumption.

Slots:
  DATA-CATEGORY: What data is being exported
  CHARACTER-ID: Whose data
  LAST-TIMESTAMP: Timestamp of the last exported record
  LAST-ID: ID of the last exported record
  TOTAL-EXPORTED: Running total of exported records
  CREATED-AT: When the checkpoint was created"
  (data-category :unknown :type keyword)
  (character-id nil :type (or null integer))
  (last-timestamp 0 :type integer)
  (last-id nil)
  (total-exported 0 :type integer)
  (created-at (get-universal-time) :type integer))

(defun incremental-export (records checkpoint &key (timestamp-field :timestamp)
                                                     (id-field :id))
  "Filter RECORDS for incremental export based on CHECKPOINT state.

Returns only records newer than the checkpoint's last-timestamp or
with IDs greater than last-id.

RECORDS: Full record list
CHECKPOINT: An export-checkpoint (NIL for full export)
TIMESTAMP-FIELD: Field containing the record timestamp
ID-FIELD: Field containing the record ID

Returns (VALUES new-records updated-checkpoint)."
  (if (null checkpoint)
      ;; Full export - return everything
      (let ((new-cp (make-export-checkpoint
                     :total-exported (length records))))
        (when records
          (let ((last-record (car (last records))))
            (setf (export-checkpoint-last-timestamp new-cp)
                  (or (getf last-record timestamp-field) 0))
            (setf (export-checkpoint-last-id new-cp)
                  (getf last-record id-field))))
        (values records new-cp))
      ;; Incremental - filter by checkpoint
      (let* ((since-ts (export-checkpoint-last-timestamp checkpoint))
             (since-id (export-checkpoint-last-id checkpoint))
             (new-records
               (remove-if
                (lambda (r)
                  (let ((ts (or (getf r timestamp-field) 0))
                        (id (getf r id-field)))
                    (or (< ts since-ts)
                        (and (= ts since-ts)
                             since-id id
                             (numberp since-id) (numberp id)
                             (<= id since-id)))))
                records))
             (updated-cp (copy-structure checkpoint)))
        (when new-records
          (let ((last-record (car (last new-records))))
            (setf (export-checkpoint-last-timestamp updated-cp)
                  (or (getf last-record timestamp-field) since-ts))
            (setf (export-checkpoint-last-id updated-cp)
                  (or (getf last-record id-field) since-id))))
        (incf (export-checkpoint-total-exported updated-cp)
              (length new-records))
        (values new-records updated-cp))))

;;; ---------------------------------------------------------------------------
;;; Export REPL utilities
;;; ---------------------------------------------------------------------------

(defun export-summary (job &optional (stream *standard-output*))
  "Print a summary of an export job.

JOB: An export-job struct
STREAM: Output stream"
  (format stream "~&=== Export Job Summary ===~%")
  (format stream "  Name:         ~A~%" (export-job-name job))
  (format stream "  ID:           ~A~%" (export-job-id job))
  (format stream "  Status:       ~A~%" (export-job-status job))
  (format stream "  Format:       ~A~%" (export-job-format job))
  (format stream "  Category:     ~A~%" (export-job-data-category job))
  (format stream "  Records:      ~D~%" (export-job-record-count job))
  (when (export-job-character-id job)
    (format stream "  Character:    ~D~%" (export-job-character-id job)))
  (when (export-job-destination job)
    (format stream "  Destination:  ~A~%" (export-job-destination job)))
  (when (export-job-error-message job)
    (format stream "  Error:        ~A~%" (export-job-error-message job)))
  (format stream "=== End Export Summary ===~%")
  (values))
