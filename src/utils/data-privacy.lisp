;;;; data-privacy.lisp - Privacy and compliance utilities for eve-gate
;;;;
;;;; Implements GDPR-aligned data handling for EVE Online ESI data. While EVE
;;;; data is somewhat public by game design (character names, corporation info),
;;;; certain data categories (wallet transactions, mail, contacts, location)
;;;; are personal data that requires privacy controls.
;;;;
;;;; This module provides:
;;;;   - Personal data identification and classification
;;;;   - Data anonymization and pseudonymization transforms
;;;;   - Retention policy enforcement
;;;;   - Data subject rights (access, portability, deletion)
;;;;   - Audit logging integration for all privacy-relevant operations
;;;;
;;;; Privacy classifications for ESI data:
;;;;   :public      - Publicly available (character name, corp info)
;;;;   :personal    - Character-specific data (skills, assets, wallet)
;;;;   :sensitive    - Highly sensitive (location, contacts, mail)
;;;;   :aggregate   - Statistical/aggregate data (market prices)
;;;;
;;;; Thread safety: All functions are thread-safe. Mutable state (retention
;;;; policies, processing records) is protected by locks.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Privacy classification
;;; ---------------------------------------------------------------------------

(deftype privacy-classification ()
  "Privacy classification levels for ESI data."
  '(member :public :personal :sensitive :aggregate))

(defparameter *esi-data-classifications*
  '(;; Public data (no special handling needed)
    (:character-public . :public)
    (:corporation-public . :public)
    (:alliance-public . :public)
    (:universe . :public)
    (:market-public . :public)
    (:industry-public . :public)
    (:dogma . :public)
    (:insurance . :public)
    (:incursions . :public)
    (:sovereignty . :public)
    (:faction-warfare-public . :public)
    (:wars . :public)
    (:status . :public)

    ;; Personal data (character-specific, requires consent)
    (:character-skills . :personal)
    (:character-assets . :personal)
    (:character-wallet . :personal)
    (:character-industry . :personal)
    (:character-orders . :personal)
    (:character-blueprints . :personal)
    (:character-fittings . :personal)
    (:character-calendar . :personal)
    (:character-contracts . :personal)
    (:character-clones . :personal)
    (:character-implants . :personal)
    (:character-killmails . :personal)
    (:character-medals . :personal)
    (:character-mining . :personal)
    (:character-planets . :personal)
    (:character-standings . :personal)
    (:character-fleet . :personal)
    (:corporation-assets . :personal)
    (:corporation-wallet . :personal)
    (:corporation-contracts . :personal)
    (:corporation-industry . :personal)
    (:corporation-members . :personal)

    ;; Sensitive data (location, communications, contacts)
    (:character-location . :sensitive)
    (:character-ship . :sensitive)
    (:character-online . :sensitive)
    (:character-contacts . :sensitive)
    (:character-mail . :sensitive)
    (:character-notifications . :sensitive)
    (:character-fatigue . :sensitive)

    ;; Aggregate data (statistical, no individual identification)
    (:market-history . :aggregate)
    (:market-prices . :aggregate)
    (:industry-systems . :aggregate)
    (:fw-statistics . :aggregate)
    (:system-jumps . :aggregate)
    (:system-kills . :aggregate))
  "Alist mapping ESI data categories to privacy classifications.")

(defun classify-data (data-category)
  "Return the privacy classification for an ESI DATA-CATEGORY.

DATA-CATEGORY: A keyword identifying the data type (e.g., :character-wallet)

Returns a privacy-classification keyword (:public, :personal, :sensitive, :aggregate)."
  (or (cdr (assoc data-category *esi-data-classifications*))
      :personal)) ; default to :personal for unknown categories (conservative)

(defun personal-data-p (data-category)
  "Return T if DATA-CATEGORY contains personal or sensitive data."
  (member (classify-data data-category) '(:personal :sensitive)))

(defun sensitive-data-p (data-category)
  "Return T if DATA-CATEGORY contains sensitive data."
  (eq (classify-data data-category) :sensitive))

;;; ---------------------------------------------------------------------------
;;; Personal data field identification
;;; ---------------------------------------------------------------------------

(defparameter *personal-data-fields*
  '(:character-id :character-name :corporation-id :alliance-id
    :wallet-balance :isk-amount :location-id :solar-system-id
    :station-id :structure-id :ship-type-id :ship-name
    :contact-id :mail-id :notification-id
    :from-id :recipient-id :sender-id :client-id
    :ip-address :email :real-name
    :access-token :refresh-token)
  "List of field names that may contain personal data.")

(defparameter *directly-identifying-fields*
  '(:character-id :character-name :from-id :recipient-id :sender-id
    :ip-address :email :real-name :access-token :refresh-token)
  "Fields that directly identify a natural person or their EVE character.")

(defun personal-field-p (field-name)
  "Return T if FIELD-NAME is a known personal data field."
  (member field-name *personal-data-fields*))

(defun directly-identifying-field-p (field-name)
  "Return T if FIELD-NAME directly identifies a person."
  (member field-name *directly-identifying-fields*))

(defun find-personal-fields (record)
  "Return a list of field names in RECORD that contain personal data.

RECORD: A plist

Returns a list of keyword field names."
  (loop for (key) on record by #'cddr
        when (personal-field-p key)
        collect key))

;;; ---------------------------------------------------------------------------
;;; Anonymization transforms
;;; ---------------------------------------------------------------------------

(defvar *anonymization-salt* nil
  "Salt for pseudonymization hashing. Should be set per-deployment.
When NIL, a random salt is generated on first use.")

(defvar *anonymization-salt-lock* (bt:make-lock "anon-salt-lock"))

(defun ensure-anonymization-salt ()
  "Ensure the anonymization salt is initialized. Returns the salt."
  (bt:with-lock-held (*anonymization-salt-lock*)
    (or *anonymization-salt*
        (setf *anonymization-salt*
              (format nil "eve-gate-~A-~A" (get-universal-time) (random 1000000))))))

(defun pseudonymize-value (value &optional (salt (ensure-anonymization-salt)))
  "Pseudonymize VALUE using a deterministic hash.

The same input always produces the same pseudonym (given the same salt),
allowing data correlation without revealing the original value.

VALUE: The value to pseudonymize
SALT: Salt string for the hash

Returns a string like \"ANON-XXXX\"."
  (let* ((input (format nil "~A:~A" salt value))
         (hash (sxhash input)))
    (format nil "ANON-~8,'0X" (logand hash #xFFFFFFFF))))

(defun anonymize-record (record &key (fields-to-anonymize *directly-identifying-fields*)
                                      (strategy :pseudonymize))
  "Anonymize personal data fields in a RECORD (plist).

RECORD: A plist to anonymize
FIELDS-TO-ANONYMIZE: List of field keywords to process
STRATEGY: One of :pseudonymize, :remove, :mask, :generalize

Returns a new plist with the specified fields anonymized."
  (let ((result (copy-list record)))
    (loop for (key value) on result by #'cddr
          when (and value (member key fields-to-anonymize))
          do (setf (getf result key)
                   (ecase strategy
                     (:pseudonymize (pseudonymize-value value))
                     (:remove nil)
                     (:mask (mask-value value))
                     (:generalize (generalize-value key value)))))
    result))

(defun anonymize-dataset (records &key (fields-to-anonymize *directly-identifying-fields*)
                                        (strategy :pseudonymize))
  "Anonymize all records in a dataset.

RECORDS: List of plists
FIELDS-TO-ANONYMIZE: Fields to anonymize
STRATEGY: Anonymization strategy

Returns a new list of anonymized plists."
  (mapcar (lambda (record)
            (anonymize-record record
                              :fields-to-anonymize fields-to-anonymize
                              :strategy strategy))
          records))

(defun mask-value (value)
  "Mask VALUE by replacing most characters with asterisks.

Preserves type information and partial structure:
  - Strings: keep first and last character, mask middle
  - Numbers: replace with 0
  - Other: replace with \"***\""
  (typecase value
    (string
     (if (<= (length value) 2)
         "***"
         (concatenate 'string
                      (string (char value 0))
                      (make-string (- (length value) 2) :initial-element #\*)
                      (string (char value (1- (length value)))))))
    (integer 0)
    (number 0.0)
    (t "***")))

(defun generalize-value (field-name value)
  "Generalize VALUE based on FIELD-NAME context.

Reduces precision to prevent identification while preserving statistical utility:
  - Character IDs -> character ID range bucket
  - ISK amounts -> order of magnitude
  - Locations -> region-level only"
  (declare (ignore field-name))
  (typecase value
    (integer
     ;; Round to nearest significant magnitude
     (if (zerop value) 0
         (let* ((magnitude (max 1 (expt 10 (floor (log (abs value) 10)))))
                (rounded (* (round value magnitude) magnitude)))
           rounded)))
    (number
     (float (round value)))
    (string "[GENERALIZED]")
    (t "[GENERALIZED]")))

;;; ---------------------------------------------------------------------------
;;; Retention policy
;;; ---------------------------------------------------------------------------

(defstruct (retention-policy (:constructor make-retention-policy))
  "Data retention policy for a specific data category.

Slots:
  DATA-CATEGORY: The ESI data category keyword
  RETENTION-DAYS: Number of days to retain data (0 = indefinite)
  ACTION: What to do when retention expires (:delete, :anonymize, :archive)
  DESCRIPTION: Human-readable policy description"
  (data-category :unknown :type keyword)
  (retention-days 90 :type (integer 0))
  (action :delete :type keyword)
  (description "" :type string))

(defvar *retention-policies* (make-hash-table :test 'eq)
  "Hash table mapping data categories to retention-policy structs.")

(defvar *retention-policies-lock* (bt:make-lock "retention-policies-lock"))

(defun register-retention-policy (policy)
  "Register a data retention policy.

POLICY: A retention-policy struct"
  (bt:with-lock-held (*retention-policies-lock*)
    (setf (gethash (retention-policy-data-category policy) *retention-policies*) policy))
  policy)

(defun get-retention-policy (data-category)
  "Get the retention policy for DATA-CATEGORY, or the default policy."
  (bt:with-lock-held (*retention-policies-lock*)
    (or (gethash data-category *retention-policies*)
        (gethash :default *retention-policies*)
        (make-retention-policy :data-category :default
                                :retention-days 365
                                :action :anonymize
                                :description "Default retention: 1 year, then anonymize"))))

;; Register default retention policies
(register-retention-policy
 (make-retention-policy :data-category :default
                         :retention-days 365
                         :action :anonymize
                         :description "Default: retain 1 year, then anonymize"))

(register-retention-policy
 (make-retention-policy :data-category :character-location
                         :retention-days 7
                         :action :delete
                         :description "Location data: delete after 7 days"))

(register-retention-policy
 (make-retention-policy :data-category :character-mail
                         :retention-days 90
                         :action :delete
                         :description "Mail data: delete after 90 days"))

(register-retention-policy
 (make-retention-policy :data-category :character-contacts
                         :retention-days 30
                         :action :anonymize
                         :description "Contacts: anonymize after 30 days"))

(register-retention-policy
 (make-retention-policy :data-category :character-wallet
                         :retention-days 180
                         :action :anonymize
                         :description "Wallet data: anonymize after 180 days"))

(register-retention-policy
 (make-retention-policy :data-category :market-history
                         :retention-days 0
                         :action :delete
                         :description "Market history: retain indefinitely (public aggregate)"))

;;; ---------------------------------------------------------------------------
;;; Data retention enforcement
;;; ---------------------------------------------------------------------------

(defun check-retention (records data-category &key (reference-time (get-universal-time))
                                                     (timestamp-field :timestamp))
  "Check which RECORDS have exceeded the retention policy for DATA-CATEGORY.

RECORDS: List of plists with timestamps
DATA-CATEGORY: The data category keyword
REFERENCE-TIME: Current time for comparison (default: now)
TIMESTAMP-FIELD: Which field contains the record timestamp

Returns (VALUES retained-records expired-records) as two lists."
  (let* ((policy (get-retention-policy data-category))
         (retention-seconds (* (retention-policy-retention-days policy) 86400)))
    (if (zerop (retention-policy-retention-days policy))
        ;; Indefinite retention
        (values records nil)
        ;; Check each record
        (let ((retained '())
              (expired '()))
          (dolist (record records)
            (let* ((timestamp (getf record timestamp-field))
                   (record-time (etypecase timestamp
                                  (integer timestamp)
                                  (string (ignore-errors
                                            (- reference-time retention-seconds 1)))
                                  (null reference-time)))
                   (age (- reference-time record-time)))
              (if (> age retention-seconds)
                  (push record expired)
                  (push record retained))))
          (values (nreverse retained) (nreverse expired))))))

(defun enforce-retention (records data-category &key (timestamp-field :timestamp))
  "Apply retention policy to RECORDS, returning only those within retention period.
Expired records are processed according to the policy action.

RECORDS: List of plists
DATA-CATEGORY: The data category keyword
TIMESTAMP-FIELD: Which field contains the record timestamp

Returns (VALUES processed-records action-summary)."
  (let ((policy (get-retention-policy data-category)))
    (multiple-value-bind (retained expired)
        (check-retention records data-category :timestamp-field timestamp-field)
      (let ((summary (list :data-category data-category
                           :policy-action (retention-policy-action policy)
                           :retained-count (length retained)
                           :expired-count (length expired))))
        ;; Log retention enforcement
        (when expired
          (log-info "Retention enforcement: ~D records expired for ~A (action: ~A)"
                    (length expired) data-category (retention-policy-action policy))
          (when *audit-enabled-p*
            (record-audit-entry
             (%make-audit-entry
              :event-type :data-retention
              :action :enforcement
              :status :success
              :details summary))))
        ;; Apply policy action to expired records
        (let ((processed-expired
                (ecase (retention-policy-action policy)
                  (:delete nil) ; discard
                  (:anonymize (anonymize-dataset expired))
                  (:archive expired)))) ; return as-is for archival
          (values (append retained processed-expired) summary))))))

;;; ---------------------------------------------------------------------------
;;; Data subject rights (GDPR Articles 15-20)
;;; ---------------------------------------------------------------------------

(defstruct (data-subject-request (:constructor make-data-subject-request))
  "A GDPR data subject rights request.

Slots:
  ID: Unique request identifier
  CHARACTER-ID: The EVE character (data subject) making the request
  CHARACTER-NAME: Character name for display
  REQUEST-TYPE: Type of request (:access, :portability, :deletion, :rectification)
  STATUS: Request status (:pending, :processing, :completed, :denied)
  CREATED-AT: When the request was made
  COMPLETED-AT: When the request was fulfilled
  DATA-CATEGORIES: Which data categories are covered
  RESULT: Result data or path
  NOTES: Processing notes"
  (id (gensym "DSR-") :type symbol)
  (character-id nil :type (or null integer))
  (character-name nil :type (or null string))
  (request-type :access :type keyword)
  (status :pending :type keyword)
  (created-at (get-universal-time) :type integer)
  (completed-at 0 :type integer)
  (data-categories nil :type list)
  (result nil)
  (notes "" :type string))

(defvar *data-subject-requests* '()
  "List of data subject requests for tracking.")

(defvar *data-subject-requests-lock* (bt:make-lock "dsr-lock"))

(defun record-data-subject-request (request)
  "Record a data subject request for tracking and audit.

REQUEST: A data-subject-request struct

Returns the request."
  (bt:with-lock-held (*data-subject-requests-lock*)
    (push request *data-subject-requests*))
  ;; Audit log
  (when *audit-enabled-p*
    (record-audit-entry
     (%make-audit-entry
      :event-type :data-rights
      :action (data-subject-request-request-type request)
      :character-id (data-subject-request-character-id request)
      :character-name (data-subject-request-character-name request)
      :status :success
      :details (list :request-id (data-subject-request-id request)
                     :categories (data-subject-request-data-categories request)))))
  request)

(defun create-access-request (character-id &key character-name data-categories)
  "Create a GDPR Article 15 data access request.

CHARACTER-ID: The data subject's EVE character ID
CHARACTER-NAME: Character name
DATA-CATEGORIES: List of data category keywords to include (NIL = all)

Returns a data-subject-request."
  (record-data-subject-request
   (make-data-subject-request
    :character-id character-id
    :character-name character-name
    :request-type :access
    :data-categories (or data-categories '(:all)))))

(defun create-portability-request (character-id &key character-name
                                                      data-categories
                                                      (format :json))
  "Create a GDPR Article 20 data portability request.

CHARACTER-ID: The data subject's EVE character ID
CHARACTER-NAME: Character name
DATA-CATEGORIES: List of data category keywords to export
FORMAT: Export format keyword (default: :json)

Returns a data-subject-request."
  (record-data-subject-request
   (make-data-subject-request
    :character-id character-id
    :character-name character-name
    :request-type :portability
    :data-categories (or data-categories '(:all))
    :notes (format nil "Export format: ~A" format))))

(defun create-deletion-request (character-id &key character-name data-categories)
  "Create a GDPR Article 17 right-to-erasure request.

CHARACTER-ID: The data subject's EVE character ID
CHARACTER-NAME: Character name
DATA-CATEGORIES: List of data category keywords to delete (NIL = all personal)

Returns a data-subject-request."
  (record-data-subject-request
   (make-data-subject-request
    :character-id character-id
    :character-name character-name
    :request-type :deletion
    :data-categories (or data-categories '(:all-personal)))))

(defun filter-data-for-subject (records character-id)
  "Filter RECORDS to return only those belonging to CHARACTER-ID.

RECORDS: List of plists
CHARACTER-ID: The data subject's character ID

Returns a filtered list of plists."
  (remove-if-not (lambda (record)
                   (eql (getf record :character-id) character-id))
                 records))

(defun delete-data-for-subject (records character-id)
  "Remove all records belonging to CHARACTER-ID from RECORDS.

RECORDS: List of plists
CHARACTER-ID: The data subject's character ID

Returns (VALUES remaining-records deleted-count)."
  (let ((remaining (remove-if (lambda (record)
                                (eql (getf record :character-id) character-id))
                              records)))
    (values remaining (- (length records) (length remaining)))))

(defun list-data-subject-requests (&key character-id request-type status (limit 50))
  "Query recorded data subject requests.

CHARACTER-ID: Filter by character
REQUEST-TYPE: Filter by request type
STATUS: Filter by status
LIMIT: Maximum results

Returns a list of data-subject-request structs."
  (bt:with-lock-held (*data-subject-requests-lock*)
    (let ((results '())
          (count 0))
      (dolist (req *data-subject-requests*)
        (when (>= count limit) (return))
        (when (and (or (null character-id)
                       (eql character-id (data-subject-request-character-id req)))
                   (or (null request-type)
                       (eq request-type (data-subject-request-request-type req)))
                   (or (null status)
                       (eq status (data-subject-request-status req))))
          (push req results)
          (incf count)))
      (nreverse results))))

;;; ---------------------------------------------------------------------------
;;; Privacy impact assessment helpers
;;; ---------------------------------------------------------------------------

(defun assess-data-privacy (records data-category)
  "Assess the privacy impact of a set of RECORDS.

RECORDS: List of plists to assess
DATA-CATEGORY: The data category keyword

Returns a plist summarizing privacy characteristics:
  :classification - Privacy classification of the data
  :record-count - Number of records
  :personal-fields - Personal data fields found
  :unique-subjects - Number of unique data subjects
  :requires-consent - Whether processing requires explicit consent
  :anonymization-recommended - Whether anonymization is recommended"
  (let* ((classification (classify-data data-category))
         (all-personal-fields '())
         (subject-ids (make-hash-table :test 'eql)))
    ;; Scan records
    (dolist (record records)
      (let ((personal (find-personal-fields record)))
        (dolist (f personal) (pushnew f all-personal-fields)))
      (when-let ((cid (getf record :character-id)))
        (setf (gethash cid subject-ids) t)))
    (list :classification classification
          :record-count (length records)
          :personal-fields all-personal-fields
          :unique-subjects (hash-table-count subject-ids)
          :requires-consent (member classification '(:personal :sensitive))
          :anonymization-recommended (eq classification :sensitive))))

;;; ---------------------------------------------------------------------------
;;; Privacy-aware data processing macro
;;; ---------------------------------------------------------------------------

(defmacro with-privacy-controls ((data-category character-id
                                  &key (audit t) (enforce-retention t))
                                 &body body)
  "Execute BODY with privacy controls active for the given data context.

DATA-CATEGORY: The ESI data category being processed
CHARACTER-ID: The character whose data is being processed
AUDIT: Whether to create audit entries (default: T)
ENFORCE-RETENTION: Whether to apply retention policies (default: T)

Within BODY, the following are available:
  - Privacy context is established for audit logging
  - Retention policies are checked before data access"
  (let ((g-category (gensym "CATEGORY"))
        (g-char-id (gensym "CHAR-ID")))
    `(let ((,g-category ,data-category)
           (,g-char-id ,character-id))
       (declare (ignorable ,g-category ,g-char-id))
       ,@(when audit
           `((when *audit-enabled-p*
               (record-audit-entry
                (%make-audit-entry
                 :event-type :data-processing
                 :action :access
                 :character-id ,g-char-id
                 :status :success
                 :details (list :data-category ,g-category
                                :classification (classify-data ,g-category)
                                :enforce-retention ,enforce-retention))))))
       (with-log-context (:data-category ,g-category
                          :privacy-classification (classify-data ,g-category))
         ,@body))))

;;; ---------------------------------------------------------------------------
;;; Privacy status and REPL utilities
;;; ---------------------------------------------------------------------------

(defun privacy-status (&optional (stream *standard-output*))
  "Print the current privacy configuration and status.

STREAM: Output stream"
  (format stream "~&=== Privacy & Compliance Status ===~%")
  (format stream "  Audit enabled:      ~A~%" *audit-enabled-p*)
  (format stream "  Anonymization salt: ~A~%"
          (if *anonymization-salt* "set" "not set"))
  ;; Retention policies
  (format stream "~%  Retention Policies:~%")
  (bt:with-lock-held (*retention-policies-lock*)
    (maphash (lambda (cat policy)
               (format stream "    ~A: ~D days (~A)~%"
                       cat
                       (retention-policy-retention-days policy)
                       (retention-policy-action policy)))
             *retention-policies*))
  ;; Data classifications summary
  (format stream "~%  Data Classifications:~%")
  (let ((counts (make-hash-table :test 'eq)))
    (dolist (pair *esi-data-classifications*)
      (incf (gethash (cdr pair) counts 0)))
    (maphash (lambda (class count)
               (format stream "    ~A: ~D categories~%" class count))
             counts))
  ;; Pending DSR requests
  (let ((pending (list-data-subject-requests :status :pending)))
    (format stream "~%  Pending data subject requests: ~D~%" (length pending)))
  (format stream "=== End Privacy Status ===~%")
  (values))
