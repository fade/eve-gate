;;;; import.lisp - Data import and validation system for eve-gate
;;;;
;;;; Provides comprehensive data import functionality with validation,
;;;; conflict resolution, merge strategies, and rollback support. Designed
;;;; for importing EVE Online ESI data from external files, other tools,
;;;; and backup archives.
;;;;
;;;; Import workflow:
;;;;   1. Detect format (auto or explicit)
;;;;   2. Parse raw data from file/stream/string
;;;;   3. Validate against schema
;;;;   4. Detect and resolve conflicts with existing data
;;;;   5. Apply data transformations/normalization
;;;;   6. Commit imported records (with rollback support)
;;;;   7. Record audit trail
;;;;
;;;; Thread safety: Import operations are designed for sequential execution
;;;; within a single thread. The import-transaction provides rollback support
;;;; via a pre-import snapshot. Audit logging uses the thread-safe audit system.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Import job definition
;;; ---------------------------------------------------------------------------

(defstruct (import-job (:constructor %make-import-job))
  "Describes a data import operation.

Slots:
  ID: Unique job identifier
  NAME: Human-readable import name
  FORMAT: Input format keyword (:json, :csv, :edn, :sexp, :auto)
  SOURCE: Input file path or :string/:stream
  DATA-CATEGORY: ESI data category for validation
  STATUS: Job status (:pending, :validating, :importing, :completed, :failed, :rolled-back)
  CREATED-AT: Creation timestamp
  COMPLETED-AT: Completion timestamp
  TOTAL-RECORDS: Total records in source
  IMPORTED-COUNT: Records successfully imported
  SKIPPED-COUNT: Records skipped (duplicates, filtered)
  ERROR-COUNT: Records that failed validation
  VALIDATION-ERRORS: List of validation error details
  MERGE-STRATEGY: How to handle conflicts (:replace, :skip, :merge, :error)
  OPTIONS: Plist of import options
  ERROR-MESSAGE: Overall error description on failure"
  (id (gensym "IMPORT-") :type symbol)
  (name "" :type string)
  (format :auto :type keyword)
  (source nil)
  (data-category :unknown :type keyword)
  (status :pending :type keyword)
  (created-at (get-universal-time) :type integer)
  (completed-at 0 :type integer)
  (total-records 0 :type integer)
  (imported-count 0 :type integer)
  (skipped-count 0 :type integer)
  (error-count 0 :type integer)
  (validation-errors nil :type list)
  (merge-strategy :skip :type keyword)
  (options nil :type list)
  (error-message nil :type (or null string)))

(defun make-import-job (name source &key (format :auto)
                                          (data-category :unknown)
                                          (merge-strategy :skip)
                                          options)
  "Create a new import job.

NAME: Human-readable import name
SOURCE: File path, string data, or stream
FORMAT: Input format (default: :auto for auto-detection)
DATA-CATEGORY: ESI data category for validation
MERGE-STRATEGY: Conflict resolution strategy:
  :replace - Overwrite existing records
  :skip - Keep existing, skip conflicts
  :merge - Merge fields (new fields supplement existing)
  :error - Signal an error on conflict
OPTIONS: Plist of options:
  :schema - Data schema for validation (or NIL to skip)
  :validate - Whether to validate records (default: T)
  :normalize - Whether to normalize field names (default: T)
  :transform-fn - Function (record) -> record for custom transformation
  :filter-fn - Predicate to filter records before import
  :batch-size - Records per batch (default: 100)
  :id-field - Field used for conflict detection (default: :id)
  :dry-run - When T, validate only without importing (default: NIL)
  :on-error - :skip, :abort, or :collect (default: :skip)

Returns an import-job struct."
  (%make-import-job
   :name name
   :source source
   :format format
   :data-category data-category
   :merge-strategy merge-strategy
   :options options))

;;; ---------------------------------------------------------------------------
;;; Import execution
;;; ---------------------------------------------------------------------------

(defun execute-import (job &key existing-data)
  "Execute an import job, reading, validating, and importing data.

JOB: An import-job struct
EXISTING-DATA: Current data for conflict detection (list of plists)

Returns (VALUES job imported-records) where imported-records is the list
of successfully imported/merged records.

Side effects:
  - Updates job status and counts
  - Records audit trail entry"
  (handler-case
      (let ((raw-records (read-import-source job)))
        (setf (import-job-total-records job) (length raw-records)
              (import-job-status job) :validating)
        ;; Validate
        (multiple-value-bind (valid-records invalid-records)
            (validate-import-records job raw-records)
          (setf (import-job-error-count job) (length invalid-records)
                (import-job-validation-errors job)
                (mapcar (lambda (pair)
                          (list :record (car pair) :errors (cdr pair)))
                        invalid-records))
          ;; Check on-error policy
          (let ((on-error (or (getf (import-job-options job) :on-error) :skip)))
            (when (and (eq on-error :abort) invalid-records)
              (setf (import-job-status job) :failed
                    (import-job-error-message job)
                    (format nil "~D validation errors; aborted" (length invalid-records)))
              (return-from execute-import (values job nil))))
          ;; Dry run check
          (when (getf (import-job-options job) :dry-run)
            (setf (import-job-status job) :completed
                  (import-job-completed-at job) (get-universal-time)
                  (import-job-imported-count job) 0)
            (return-from execute-import (values job valid-records)))
          ;; Import with conflict resolution
          (setf (import-job-status job) :importing)
          (multiple-value-bind (imported skipped)
              (resolve-and-merge job valid-records existing-data)
            (setf (import-job-status job) :completed
                  (import-job-completed-at job) (get-universal-time)
                  (import-job-imported-count job) (length imported)
                  (import-job-skipped-count job) skipped)
            ;; Audit
            (audit-import-operation job)
            (values job imported))))
    (error (e)
      (setf (import-job-status job) :failed
            (import-job-error-message job) (princ-to-string e))
      (log-error "Import failed: ~A (job: ~A)" e (import-job-name job))
      (values job nil))))

;;; ---------------------------------------------------------------------------
;;; Source reading
;;; ---------------------------------------------------------------------------

(defun read-import-source (job)
  "Read and parse the import source, returning a list of plists.

JOB: An import-job struct

Returns a list of plists."
  (let* ((source (import-job-source job))
         (format (detect-import-format job))
         (raw-data (etypecase source
                     (string
                      ;; Could be a file path or inline data
                      ;; Check if it looks like a file path (not starting with data chars)
                      (if (and (> (length source) 0)
                               (not (member (char source 0) '(#\[ #\{ #\( #\< #\:)))
                               (ignore-errors (probe-file source)))
                          (read-import-file source format)
                          (decode-from-string source format)))
                     (pathname
                      (read-import-file source format))
                     (stream
                      (decode-data format source))))
         (records (ensure-list-of-plists raw-data))
         (options (import-job-options job)))
    ;; Apply normalization
    (when (getf options :normalize t)
      (setf records (mapcar #'normalize-import-record records)))
    ;; Apply custom transform
    (when-let ((transform-fn (getf options :transform-fn)))
      (setf records (mapcar transform-fn records)))
    ;; Apply filter
    (when-let ((filter-fn (getf options :filter-fn)))
      (setf records (remove-if-not filter-fn records)))
    ;; Handle metadata wrapper (if data has :metadata and :data keys)
    (when (and (= 1 (length records))
               (getf (first records) :data))
      (let ((inner (getf (first records) :data)))
        (when (listp inner)
          (setf records (ensure-list-of-plists inner)))))
    records))

(defun detect-import-format (job)
  "Detect the format for an import job. Returns a format keyword."
  (let ((format (import-job-format job))
        (source (import-job-source job)))
    (if (eq format :auto)
        (etypecase source
          (pathname (or (detect-format-from-path source) :json))
          (string (if (probe-file source)
                      (or (detect-format-from-path source) :json)
                      (detect-format-from-content source)))
          (stream :json))
        format)))

(defun read-import-file (path format)
  "Read and decode a file at PATH in the given FORMAT."
  (with-open-file (stream path :direction :input
                                :external-format :utf-8)
    (decode-data format stream)))

(defun normalize-import-record (record)
  "Normalize an imported record's field names to standard keywords.

Converts string keys to keywords, snake_case to kebab-case, etc."
  (let ((result '()))
    (loop for (key value) on record by #'cddr
          for normalized-key = (normalize-field-name key)
          do (setf (getf result normalized-key) (normalize-value value)))
    result))

(defun normalize-field-name (name)
  "Normalize a field name to a keyword."
  (etypecase name
    (keyword name)
    (string (intern (string-upcase (substitute #\- #\_ (substitute #\- #\Space name)))
                    :keyword))
    (symbol (intern (symbol-name name) :keyword))))

;;; ---------------------------------------------------------------------------
;;; Validation
;;; ---------------------------------------------------------------------------

(defun validate-import-records (job records)
  "Validate import records against the job's schema.

JOB: The import job
RECORDS: List of plists to validate

Returns (VALUES valid-records invalid-pairs) where invalid-pairs is
a list of (record . error-list) cons cells."
  (let ((schema (getf (import-job-options job) :schema))
        (do-validate (getf (import-job-options job) :validate t)))
    (if (and do-validate schema)
        (let ((valid '())
              (invalid '()))
          (dolist (record records)
            (multiple-value-bind (valid-p errors)
                (validate-record-against-schema record schema)
              (if valid-p
                  (push record valid)
                  (push (cons record errors) invalid))))
          (values (nreverse valid) (nreverse invalid)))
        ;; No validation - all records pass
        (values records nil))))

;;; ---------------------------------------------------------------------------
;;; Conflict resolution and merging
;;; ---------------------------------------------------------------------------

(defun resolve-and-merge (job new-records existing-data)
  "Resolve conflicts between NEW-RECORDS and EXISTING-DATA, applying the merge strategy.

JOB: The import job
NEW-RECORDS: Validated new records to import
EXISTING-DATA: Current data for conflict detection

Returns (VALUES merged-records skipped-count)."
  (let* ((strategy (import-job-merge-strategy job))
         (id-field (or (getf (import-job-options job) :id-field) :id))
         (existing-index (when existing-data
                           (index-records-by-field existing-data id-field)))
         (merged '())
         (skipped 0))
    (dolist (record new-records)
      (let* ((record-id (getf record id-field))
             (existing (when (and record-id existing-index)
                         (gethash record-id existing-index))))
        (if existing
            ;; Conflict detected
            (ecase strategy
              (:replace
               (push record merged))
              (:skip
               (incf skipped))
              (:merge
               (push (merge-records existing record) merged))
              (:error
               (error "Import conflict: record with ~A=~A already exists"
                      id-field record-id)))
            ;; No conflict
            (push record merged))))
    ;; Include non-conflicting existing records in merged result
    (when (and existing-data (member strategy '(:replace :merge)))
      (let ((imported-ids (make-hash-table :test 'equal)))
        (dolist (r merged)
          (when-let ((id (getf r id-field)))
            (setf (gethash id imported-ids) t)))
        (dolist (r existing-data)
          (let ((id (getf r id-field)))
            (unless (gethash id imported-ids)
              (push r merged))))))
    (values (nreverse merged) skipped)))

(defun index-records-by-field (records field)
  "Build a hash-table index of RECORDS keyed by FIELD value."
  (let ((index (make-hash-table :test 'equal :size (length records))))
    (dolist (record records)
      (when-let ((key (getf record field)))
        (setf (gethash key index) record)))
    index))

(defun merge-records (existing new)
  "Merge two plists: NEW fields supplement EXISTING fields.
Fields from NEW override EXISTING when both are present."
  (let ((result (copy-list existing)))
    (loop for (key value) on new by #'cddr
          do (setf (getf result key) value))
    result))

;;; ---------------------------------------------------------------------------
;;; Import transaction (rollback support)
;;; ---------------------------------------------------------------------------

(defstruct (import-transaction (:constructor %make-import-transaction))
  "Tracks an import operation for potential rollback.

Slots:
  ID: Transaction identifier
  JOB: The import job
  SNAPSHOT: Pre-import state of existing data
  IMPORTED: Records that were imported
  STATUS: :active, :committed, :rolled-back"
  (id (gensym "TXN-") :type symbol)
  (job nil :type (or null import-job))
  (snapshot nil :type list)
  (imported nil :type list)
  (status :active :type keyword))

(defun begin-import-transaction (job existing-data)
  "Begin a new import transaction, snapshotting existing data.

JOB: The import job
EXISTING-DATA: Current data to snapshot for rollback

Returns an import-transaction."
  (%make-import-transaction
   :job job
   :snapshot (copy-list existing-data)))

(defun commit-import-transaction (txn imported-records)
  "Commit an import transaction.

TXN: The transaction to commit
IMPORTED-RECORDS: Records that were successfully imported

Returns the imported records."
  (setf (import-transaction-imported txn) imported-records
        (import-transaction-status txn) :committed)
  (log-info "Import transaction ~A committed: ~D records"
            (import-transaction-id txn) (length imported-records))
  imported-records)

(defun rollback-import-transaction (txn)
  "Roll back an import transaction, returning the pre-import snapshot.

TXN: The transaction to roll back

Returns the snapshot data (pre-import state)."
  (setf (import-transaction-status txn) :rolled-back)
  (when (import-transaction-job txn)
    (setf (import-job-status (import-transaction-job txn)) :rolled-back))
  (log-warn "Import transaction ~A rolled back" (import-transaction-id txn))
  (import-transaction-snapshot txn))

(defmacro with-import-transaction ((txn-var job existing-data) &body body)
  "Execute BODY within an import transaction that rolls back on error.

TXN-VAR: Variable bound to the transaction within BODY
JOB: The import job
EXISTING-DATA: Current data to snapshot

On success, commits the transaction. On error, rolls back.

Example:
  (with-import-transaction (txn job current-data)
    (execute-import job :existing-data current-data))"
  (let ((g-result (gensym "RESULT")))
    `(let ((,txn-var (begin-import-transaction ,job ,existing-data)))
       (handler-case
           (let ((,g-result (progn ,@body)))
             (commit-import-transaction ,txn-var ,g-result)
             ,g-result)
         (error (e)
           (log-error "Import transaction error, rolling back: ~A" e)
           (rollback-import-transaction ,txn-var)
           (error e))))))

;;; ---------------------------------------------------------------------------
;;; Batch import
;;; ---------------------------------------------------------------------------

(defun batch-import (job &key existing-data progress-fn)
  "Execute an import job in batches with progress tracking.

JOB: The import job
EXISTING-DATA: Current data for conflict resolution
PROGRESS-FN: Optional function (batch-num total-batches imported-so-far) for tracking

Returns (VALUES job all-imported-records)."
  (let* ((batch-size (or (getf (import-job-options job) :batch-size) 100))
         (records (read-import-source job))
         (total (length records))
         (batches (partition-into-batches records batch-size))
         (num-batches (length batches))
         (all-imported '())
         (total-imported 0)
         (total-skipped 0))
    (setf (import-job-total-records job) total
          (import-job-status job) :importing)
    (loop for batch in batches
          for batch-num from 1
          do (multiple-value-bind (imported skipped)
                 (resolve-and-merge job batch existing-data)
               (incf total-imported (length imported))
               (incf total-skipped skipped)
               (setf all-imported (nconc all-imported imported))
               ;; Update existing-data for subsequent batches
               (when (member (import-job-merge-strategy job) '(:replace :merge))
                 (setf existing-data imported))
               ;; Progress callback
               (when progress-fn
                 (funcall progress-fn batch-num num-batches total-imported))))
    (setf (import-job-status job) :completed
          (import-job-completed-at job) (get-universal-time)
          (import-job-imported-count job) total-imported
          (import-job-skipped-count job) total-skipped)
    (audit-import-operation job)
    (values job all-imported)))

(defun partition-into-batches (list batch-size)
  "Partition LIST into sublists of at most BATCH-SIZE elements."
  (loop for tail on list by (lambda (l) (nthcdr batch-size l))
        collect (subseq tail 0 (min batch-size (length tail)))))

;;; ---------------------------------------------------------------------------
;;; Audit integration
;;; ---------------------------------------------------------------------------

(defun audit-import-operation (job)
  "Record an audit entry for an import operation."
  (when *audit-enabled-p*
    (record-audit-entry
     (%make-audit-entry
      :event-type :data-import
      :action :import
      :status (if (eq (import-job-status job) :completed) :success :error)
      :details (list :import-name (import-job-name job)
                     :data-category (import-job-data-category job)
                     :total-records (import-job-total-records job)
                     :imported (import-job-imported-count job)
                     :skipped (import-job-skipped-count job)
                     :errors (import-job-error-count job)
                     :merge-strategy (import-job-merge-strategy job))))))

;;; ---------------------------------------------------------------------------
;;; High-level import functions
;;; ---------------------------------------------------------------------------

(defun import-from-file (path &key (format :auto)
                                    (data-category :unknown)
                                    (merge-strategy :skip)
                                    schema
                                    existing-data
                                    transform-fn)
  "Import data from a file with validation and conflict resolution.

PATH: File path to import from
FORMAT: Data format (default: :auto for auto-detection)
DATA-CATEGORY: ESI data category for validation
MERGE-STRATEGY: Conflict resolution strategy
SCHEMA: Data schema for validation (NIL to skip)
EXISTING-DATA: Current data for conflict detection
TRANSFORM-FN: Optional record transformation function

Returns (VALUES import-job imported-records)."
  (let ((job (make-import-job
              (format nil "Import from ~A" (file-namestring path))
              (pathname path)
              :format format
              :data-category data-category
              :merge-strategy merge-strategy
              :options (list :schema schema
                             :transform-fn transform-fn
                             :validate (not (null schema))))))
    (execute-import job :existing-data existing-data)))

(defun import-from-string (string &key (format :auto)
                                        (data-category :unknown)
                                        (merge-strategy :skip)
                                        schema
                                        existing-data)
  "Import data from a string with validation.

STRING: Encoded data string
FORMAT: Data format (default: :auto)
DATA-CATEGORY: ESI data category
MERGE-STRATEGY: Conflict resolution strategy
SCHEMA: Validation schema
EXISTING-DATA: Current data for conflict detection

Returns (VALUES import-job imported-records)."
  (let ((job (make-import-job
              "String import"
              string
              :format format
              :data-category data-category
              :merge-strategy merge-strategy
              :options (list :schema schema
                             :validate (not (null schema))))))
    (execute-import job :existing-data existing-data)))

(defun validate-import-file (path &key (format :auto) schema)
  "Validate a file for import without actually importing (dry run).

PATH: File path
FORMAT: Data format
SCHEMA: Validation schema

Returns (VALUES import-job validation-summary)."
  (let ((job (make-import-job
              (format nil "Validate ~A" (file-namestring path))
              (pathname path)
              :format format
              :options (list :schema schema
                             :validate (not (null schema))
                             :dry-run t))))
    (execute-import job)
    (values job
            (list :total-records (import-job-total-records job)
                  :valid-count (- (import-job-total-records job)
                                  (import-job-error-count job))
                  :error-count (import-job-error-count job)
                  :errors (import-job-validation-errors job)))))

;;; ---------------------------------------------------------------------------
;;; Import REPL utilities
;;; ---------------------------------------------------------------------------

(defun import-summary (job &optional (stream *standard-output*))
  "Print a summary of an import job.

JOB: An import-job struct
STREAM: Output stream"
  (format stream "~&=== Import Job Summary ===~%")
  (format stream "  Name:         ~A~%" (import-job-name job))
  (format stream "  ID:           ~A~%" (import-job-id job))
  (format stream "  Status:       ~A~%" (import-job-status job))
  (format stream "  Format:       ~A~%" (import-job-format job))
  (format stream "  Category:     ~A~%" (import-job-data-category job))
  (format stream "  Total:        ~D records~%" (import-job-total-records job))
  (format stream "  Imported:     ~D~%" (import-job-imported-count job))
  (format stream "  Skipped:      ~D~%" (import-job-skipped-count job))
  (format stream "  Errors:       ~D~%" (import-job-error-count job))
  (format stream "  Strategy:     ~A~%" (import-job-merge-strategy job))
  (when (import-job-error-message job)
    (format stream "  Error:        ~A~%" (import-job-error-message job)))
  (when (import-job-validation-errors job)
    (format stream "~%  Validation Errors (first 5):~%")
    (loop for err in (import-job-validation-errors job)
          for i from 0 below 5
          do (format stream "    Record ~D: ~{~A~^; ~}~%"
                     i (getf err :errors))))
  (format stream "=== End Import Summary ===~%")
  (values))
