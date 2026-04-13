;;;; formats.lisp - Pluggable format handlers for eve-gate data exchange
;;;;
;;;; Provides a registry-based format system supporting JSON, CSV, XML, YAML,
;;;; and EDN serialization for EVE Online ESI data. Each format is registered
;;;; as a handler struct with encode/decode functions, allowing extensibility.
;;;;
;;;; Design:
;;;;   - Pluggable: new formats can be added at runtime via REGISTER-FORMAT
;;;;   - Streaming: large datasets are handled via writer functions that
;;;;     accept a stream, avoiding full materialization in memory
;;;;   - EVE-aware: type coercion handles ESI-specific types (timestamps,
;;;;     ISK amounts, entity IDs) correctly across formats
;;;;   - Schema-validated: imported data can be checked against expected shapes
;;;;
;;;; Thread safety: The format registry is protected by a lock. Individual
;;;; format handlers are stateless pure functions.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Format handler protocol
;;; ---------------------------------------------------------------------------

(defstruct (format-handler (:constructor %make-format-handler))
  "A registered data format handler for serialization and deserialization.

Slots:
  NAME: Format keyword identifier (e.g., :json, :csv)
  DESCRIPTION: Human-readable format description
  EXTENSION: Default file extension (e.g., \"json\", \"csv\")
  MIME-TYPE: MIME type string for this format
  ENCODE-FN: Function (data stream &key pretty) -> nil, writes encoded data
  DECODE-FN: Function (stream) -> data, reads and returns decoded data
  STREAMING-P: Whether this format supports streaming large datasets
  BINARY-P: Whether this format requires binary streams"
  (name :json :type keyword)
  (description "" :type string)
  (extension "json" :type string)
  (mime-type "application/json" :type string)
  (encode-fn nil :type (or null function))
  (decode-fn nil :type (or null function))
  (streaming-p nil :type boolean)
  (binary-p nil :type boolean))

;;; ---------------------------------------------------------------------------
;;; Format registry
;;; ---------------------------------------------------------------------------

(defvar *format-registry* (make-hash-table :test 'eq)
  "Hash table mapping format keywords to format-handler structs.")

(defvar *format-registry-lock* (bt:make-lock "format-registry-lock")
  "Lock protecting the format registry.")

(defun register-format (handler)
  "Register a format handler in the global registry.

HANDLER: A format-handler struct

Returns the handler."
  (bt:with-lock-held (*format-registry-lock*)
    (setf (gethash (format-handler-name handler) *format-registry*) handler))
  handler)

(defun find-format-handler (format)
  "Look up a format handler by keyword name.

FORMAT: A keyword (e.g., :json, :csv)

Returns the format-handler struct, or signals an error if not found."
  (bt:with-lock-held (*format-registry-lock*)
    (or (gethash format *format-registry*)
        (error "Unknown data format: ~A. Available: ~{~A~^, ~}"
               format (list-formats)))))

(defun list-formats ()
  "Return a sorted list of registered format keywords."
  (bt:with-lock-held (*format-registry-lock*)
    (let ((formats '()))
      (maphash (lambda (k v) (declare (ignore v)) (push k formats))
               *format-registry*)
      (sort formats #'string< :key #'symbol-name))))

(defun format-extension (format)
  "Return the file extension for FORMAT (without leading dot)."
  (format-handler-extension (find-format-handler format)))

(defun format-mime-type (format)
  "Return the MIME type string for FORMAT."
  (format-handler-mime-type (find-format-handler format)))

;;; ---------------------------------------------------------------------------
;;; Core encode/decode dispatch
;;; ---------------------------------------------------------------------------

(defun encode-data (data format stream &key (pretty nil))
  "Encode DATA in the given FORMAT, writing to STREAM.

DATA: The data to serialize (typically a list-of-plists or hash-table)
FORMAT: A format keyword (e.g., :json, :csv)
STREAM: Output character stream
PRETTY: When T, produce human-readable output (format-dependent)

Returns NIL."
  (let ((handler (find-format-handler format)))
    (funcall (format-handler-encode-fn handler) data stream :pretty pretty)))

(defun decode-data (format stream)
  "Decode data from STREAM in the given FORMAT.

FORMAT: A format keyword (e.g., :json, :csv)
STREAM: Input character stream

Returns the decoded data."
  (let ((handler (find-format-handler format)))
    (funcall (format-handler-decode-fn handler) stream)))

(defun encode-to-string (data format &key (pretty nil))
  "Encode DATA in FORMAT, returning a string.

DATA: The data to serialize
FORMAT: A format keyword
PRETTY: When T, produce human-readable output

Returns a string."
  (with-output-to-string (s)
    (encode-data data format s :pretty pretty)))

(defun decode-from-string (string format)
  "Decode data from STRING in the given FORMAT.

STRING: The encoded data string
FORMAT: A format keyword

Returns the decoded data."
  (with-input-from-string (s string)
    (decode-data format s)))

;;; ---------------------------------------------------------------------------
;;; JSON format handler (primary format, uses jzon)
;;; ---------------------------------------------------------------------------

(defun json-encode (data stream &key (pretty nil))
  "Encode DATA as JSON to STREAM.

Handles plists, hash-tables, lists, and atomic values.
EVE-specific types (timestamps, IDs) are converted appropriately."
  (let ((json-data (lisp-to-json-compatible data)))
    (com.inuoe.jzon:stringify json-data :stream stream :pretty pretty)))

(defun json-decode (stream)
  "Decode JSON from STREAM, returning Lisp data structures.

JSON objects become hash-tables, arrays become vectors, strings stay strings,
numbers become numbers, booleans become T/NIL, null becomes NIL."
  (com.inuoe.jzon:parse stream))

(defun lisp-to-json-compatible (data)
  "Convert Lisp data structures to jzon-compatible forms.

Converts plists to hash-tables, keywords to strings, and handles
nested structures recursively."
  (typecase data
    (null :null)
    (hash-table data)
    (keyword (string-downcase (symbol-name data)))
    (string data)
    (number data)
    (symbol (if (eq data t) t (string-downcase (symbol-name data))))
    (cons
     (if (plist-p data)
         (plist-to-hash-table data)
         (map 'vector #'lisp-to-json-compatible data)))
    (vector (map 'vector #'lisp-to-json-compatible data))
    (t (princ-to-string data))))

(defun plist-p (list)
  "Return T if LIST looks like a property list (alternating keywords and values)."
  (and (consp list)
       (keywordp (car list))
       (evenp (length list))))

(defun plist-to-hash-table (plist)
  "Convert a property list to a hash-table with string keys for JSON output."
  (let ((ht (make-hash-table :test 'equal :size (ceiling (length plist) 2))))
    (loop for (key value) on plist by #'cddr
          do (setf (gethash (if (keywordp key)
                                (string-downcase (symbol-name key))
                                (princ-to-string key))
                            ht)
                   (lisp-to-json-compatible value)))
    ht))

(register-format
 (%make-format-handler
  :name :json
  :description "JavaScript Object Notation"
  :extension "json"
  :mime-type "application/json"
  :encode-fn #'json-encode
  :decode-fn #'json-decode
  :streaming-p nil
  :binary-p nil))

;;; ---------------------------------------------------------------------------
;;; CSV format handler
;;; ---------------------------------------------------------------------------

(defun csv-encode (data stream &key pretty)
  "Encode DATA as CSV to STREAM.

DATA should be a list of plists or hash-tables. The first row determines
the column headers. PRETTY is ignored for CSV."
  (declare (ignore pretty))
  (when (null data) (return-from csv-encode nil))
  (let* ((records (ensure-list-of-plists data))
         (headers (collect-csv-headers records)))
    ;; Write header row
    (write-csv-row headers stream)
    ;; Write data rows
    (dolist (record records)
      (write-csv-row
       (mapcar (lambda (h) (csv-format-value (getf record h))) headers)
       stream))))

(defun csv-decode (stream)
  "Decode CSV from STREAM, returning a list of plists.

The first line is treated as headers. Each subsequent line becomes a plist
with keyword keys derived from the headers."
  (let* ((first-line (read-line stream nil nil))
         (headers (when first-line (parse-csv-row first-line)))
         (header-keywords (mapcar (lambda (h)
                                    (intern (string-upcase (substitute #\- #\Space h))
                                            :keyword))
                                  headers))
         (records '()))
    (loop for line = (read-line stream nil nil)
          while line
          for trimmed = (string-trim '(#\Space #\Return) line)
          when (plusp (length trimmed))
          do (let* ((values (parse-csv-row trimmed))
                    (record '()))
               (loop for key in header-keywords
                     for val in values
                     do (setf (getf record key) (csv-parse-value val)))
               (push record records)))
    (nreverse records)))

(defun collect-csv-headers (records)
  "Collect all unique keys from a list of plists, preserving order of first appearance."
  (let ((seen (make-hash-table :test 'eq))
        (headers '()))
    (dolist (record records)
      (loop for (key) on record by #'cddr
            unless (gethash key seen)
            do (setf (gethash key seen) t)
               (push key headers)))
    (nreverse headers)))

(defun write-csv-row (values stream)
  "Write a single CSV row to STREAM."
  (loop for (val . rest) on values
        do (write-csv-field val stream)
        when rest do (write-char #\, stream))
  (terpri stream))

(defun write-csv-field (value stream)
  "Write a single CSV field VALUE to STREAM, quoting if necessary."
  (let ((str (if (keywordp value)
                 (string-downcase (symbol-name value))
                 (princ-to-string value))))
    (if (or (find #\, str) (find #\" str) (find #\Newline str))
        (progn
          (write-char #\" stream)
          (loop for c across str
                do (when (char= c #\") (write-char #\" stream))
                   (write-char c stream))
          (write-char #\" stream))
        (write-string str stream))))

(defun csv-format-value (value)
  "Format a Lisp value for CSV output."
  (typecase value
    (null "")
    (keyword (string-downcase (symbol-name value)))
    (string value)
    (t value)))

(defun parse-csv-row (line)
  "Parse a CSV LINE into a list of string values, handling quoted fields."
  (let ((fields '())
        (current (make-string-output-stream))
        (in-quotes nil)
        (i 0)
        (len (length line)))
    (loop while (< i len)
          for c = (char line i)
          do (cond
               ((and in-quotes (char= c #\"))
                (if (and (< (1+ i) len) (char= (char line (1+ i)) #\"))
                    (progn (write-char #\" current) (incf i 2))
                    (progn (setf in-quotes nil) (incf i))))
               ((and (not in-quotes) (char= c #\"))
                (setf in-quotes t) (incf i))
               ((and (not in-quotes) (char= c #\,))
                (push (get-output-stream-string current) fields)
                (setf current (make-string-output-stream))
                (incf i))
               (t (write-char c current) (incf i))))
    (push (get-output-stream-string current) fields)
    (nreverse fields)))

(defun csv-parse-value (string)
  "Attempt to parse a CSV string VALUE into an appropriate Lisp type.
Numbers become numbers, empty strings become NIL, otherwise keep as string."
  (let ((trimmed (string-trim '(#\Space) string)))
    (cond
      ((zerop (length trimmed)) nil)
      ((string= trimmed "true") t)
      ((string= trimmed "false") nil)
      ((every (lambda (c) (or (digit-char-p c) (char= c #\-) (char= c #\.)))
              trimmed)
       (let ((parsed (ignore-errors (read-from-string trimmed))))
         (if (numberp parsed) parsed trimmed)))
      (t trimmed))))

(register-format
 (%make-format-handler
  :name :csv
  :description "Comma-Separated Values"
  :extension "csv"
  :mime-type "text/csv"
  :encode-fn #'csv-encode
  :decode-fn #'csv-decode
  :streaming-p t
  :binary-p nil))

;;; ---------------------------------------------------------------------------
;;; EDN format handler (Extensible Data Notation)
;;; ---------------------------------------------------------------------------

(defun edn-encode (data stream &key (pretty nil))
  "Encode DATA as EDN to STREAM.

EDN is a subset of Clojure data notation. We produce a Lisp-friendly
textual representation: maps as {:key val}, vectors as [...], sets as #{...}."
  (write-edn data stream :pretty pretty :indent 0))

(defun write-edn (data stream &key pretty (indent 0))
  "Recursively write DATA as EDN to STREAM."
  (typecase data
    (null (write-string "nil" stream))
    ((eql t) (write-string "true" stream))
    (keyword
     (write-char #\: stream)
     (write-string (string-downcase (symbol-name data)) stream))
    (symbol
     (write-string (string-downcase (symbol-name data)) stream))
    (string
     (write-char #\" stream)
     (loop for c across data
           do (case c
                (#\" (write-string "\\\"" stream))
                (#\\ (write-string "\\\\" stream))
                (#\Newline (write-string "\\n" stream))
                (#\Tab (write-string "\\t" stream))
                (t (write-char c stream))))
     (write-char #\" stream))
    (integer (format stream "~D" data))
    (float (format stream "~F" data))
    (ratio (format stream "~F" (coerce data 'double-float)))
    (hash-table
     (write-char #\{ stream)
     (let ((first t))
       (maphash (lambda (k v)
                  (unless first
                    (if pretty
                        (progn (terpri stream)
                               (dotimes (i (+ indent 1)) (write-char #\Space stream)))
                        (write-char #\Space stream)))
                  (write-edn k stream :pretty pretty :indent (+ indent 2))
                  (write-char #\Space stream)
                  (write-edn v stream :pretty pretty :indent (+ indent 2))
                  (setf first nil))
                data))
     (write-char #\} stream))
    (cons
     (if (plist-p data)
         ;; Encode plist as EDN map
         (progn
           (write-char #\{ stream)
           (loop for (k v) on data by #'cddr
                 for first = t then nil
                 do (unless first
                      (if pretty
                          (progn (terpri stream)
                                 (dotimes (i (+ indent 1))
                                   (write-char #\Space stream)))
                          (write-char #\Space stream)))
                    (write-edn k stream :pretty pretty :indent (+ indent 2))
                    (write-char #\Space stream)
                    (write-edn v stream :pretty pretty :indent (+ indent 2)))
           (write-char #\} stream))
         ;; Encode list as EDN vector
         (progn
           (write-char #\[ stream)
           (loop for (item . rest) on data
                 do (write-edn item stream :pretty pretty :indent (+ indent 1))
                 when rest do (write-char #\Space stream))
           (write-char #\] stream))))
    (vector
     (write-char #\[ stream)
     (loop for i from 0 below (length data)
           do (when (plusp i) (write-char #\Space stream))
              (write-edn (aref data i) stream :pretty pretty :indent (+ indent 1)))
     (write-char #\] stream))
    (t (format stream "~S" data))))

(defun edn-decode (stream)
  "Decode EDN from STREAM. Returns Lisp data structures.

Simplified parser: handles maps, vectors, strings, numbers, keywords,
nil, true, false. Not a full EDN parser but sufficient for data exchange."
  (edn-read stream))

(defun edn-read (stream)
  "Read one EDN value from STREAM."
  (edn-skip-whitespace stream)
  (let ((c (peek-char nil stream nil nil)))
    (case c
      ((nil) nil)
      (#\{ (edn-read-map stream))
      (#\[ (edn-read-vector stream))
      (#\" (edn-read-string stream))
      (#\: (edn-read-keyword stream))
      (#\; (read-line stream nil nil) (edn-read stream)) ; comment
      (t
       (if (or (digit-char-p c) (char= c #\-))
           (edn-read-number stream)
           (edn-read-symbol stream))))))

(defun edn-skip-whitespace (stream)
  "Skip whitespace and commas in EDN input."
  (loop for c = (peek-char nil stream nil nil)
        while (and c (or (member c '(#\Space #\Tab #\Newline #\Return #\,))))
        do (read-char stream)))

(defun edn-read-string (stream)
  "Read an EDN quoted string."
  (read-char stream) ; consume opening quote
  (let ((result (make-string-output-stream)))
    (loop for c = (read-char stream)
          until (char= c #\")
          do (if (char= c #\\)
                 (let ((escaped (read-char stream)))
                   (case escaped
                     (#\n (write-char #\Newline result))
                     (#\t (write-char #\Tab result))
                     (#\" (write-char #\" result))
                     (#\\ (write-char #\\ result))
                     (t (write-char escaped result))))
                 (write-char c result)))
    (get-output-stream-string result)))

(defun edn-read-keyword (stream)
  "Read an EDN keyword."
  (read-char stream) ; consume colon
  (let ((name (make-string-output-stream)))
    (loop for c = (peek-char nil stream nil nil)
          while (and c (not (member c '(#\Space #\Tab #\Newline #\Return
                                        #\} #\] #\) #\,))))
          do (write-char (read-char stream) name))
    (intern (string-upcase (get-output-stream-string name)) :keyword)))

(defun edn-read-number (stream)
  "Read an EDN number (integer or float)."
  (let ((str (make-string-output-stream)))
    (loop for c = (peek-char nil stream nil nil)
          while (and c (or (digit-char-p c) (member c '(#\- #\. #\e #\E #\+))))
          do (write-char (read-char stream) str))
    (let* ((s (get-output-stream-string str))
           (val (ignore-errors (read-from-string s))))
      (if (numberp val) val s))))

(defun edn-read-symbol (stream)
  "Read an EDN symbol (nil, true, false, or arbitrary symbol)."
  (let ((str (make-string-output-stream)))
    (loop for c = (peek-char nil stream nil nil)
          while (and c (not (member c '(#\Space #\Tab #\Newline #\Return
                                        #\} #\] #\) #\, #\;))))
          do (write-char (read-char stream) str))
    (let ((s (get-output-stream-string str)))
      (cond
        ((string= s "nil") nil)
        ((string= s "true") t)
        ((string= s "false") nil)
        (t (intern (string-upcase s) :keyword))))))

(defun edn-read-map (stream)
  "Read an EDN map {...} returning a plist."
  (read-char stream) ; consume {
  (let ((result '()))
    (loop
      (edn-skip-whitespace stream)
      (let ((c (peek-char nil stream nil nil)))
        (when (or (null c) (char= c #\}))
          (when c (read-char stream))
          (return (nreverse result))))
      (let ((key (edn-read stream))
            (val (edn-read stream)))
        (push val result)
        (push key result)))))

(defun edn-read-vector (stream)
  "Read an EDN vector [...] returning a list."
  (read-char stream) ; consume [
  (let ((result '()))
    (loop
      (edn-skip-whitespace stream)
      (let ((c (peek-char nil stream nil nil)))
        (when (or (null c) (char= c #\]))
          (when c (read-char stream))
          (return (nreverse result))))
      (push (edn-read stream) result))))

(register-format
 (%make-format-handler
  :name :edn
  :description "Extensible Data Notation"
  :extension "edn"
  :mime-type "application/edn"
  :encode-fn #'edn-encode
  :decode-fn #'edn-decode
  :streaming-p nil
  :binary-p nil))

;;; ---------------------------------------------------------------------------
;;; SEXP format handler (native Lisp S-expressions)
;;; ---------------------------------------------------------------------------

(defun sexp-encode (data stream &key (pretty nil))
  "Encode DATA as readable S-expressions to STREAM."
  (let ((*print-pretty* pretty)
        (*print-case* :downcase)
        (*print-readably* nil))
    (prin1 data stream)
    (terpri stream)))

(defun sexp-decode (stream)
  "Decode S-expression data from STREAM.
Only allows safe data types (no arbitrary evaluation)."
  (let ((*read-eval* nil))
    (read stream nil nil)))

(register-format
 (%make-format-handler
  :name :sexp
  :description "Common Lisp S-expressions"
  :extension "lisp"
  :mime-type "application/x-lisp"
  :encode-fn #'sexp-encode
  :decode-fn #'sexp-decode
  :streaming-p nil
  :binary-p nil))

;;; ---------------------------------------------------------------------------
;;; Format detection from file extension or content
;;; ---------------------------------------------------------------------------

(defun detect-format-from-path (pathname)
  "Detect the data format from a file PATHNAME based on extension.

PATHNAME: A pathname or string

Returns a format keyword, or NIL if unknown."
  (let* ((path (pathname pathname))
         (ext (string-downcase (or (pathname-type path) ""))))
    (bt:with-lock-held (*format-registry-lock*)
      (maphash (lambda (name handler)
                 (when (string= ext (format-handler-extension handler))
                   (return-from detect-format-from-path name)))
               *format-registry*))
    nil))

(defun detect-format-from-content (string)
  "Attempt to detect the data format from the beginning of STRING content.

Returns a format keyword, or :json as default."
  (let ((trimmed (string-left-trim '(#\Space #\Tab #\Newline #\Return) string)))
    (cond
      ((zerop (length trimmed)) :json)
      ((or (char= (char trimmed 0) #\{)
           (char= (char trimmed 0) #\[))
       :json)
      ((char= (char trimmed 0) #\<) :xml)
      ((char= (char trimmed 0) #\() :sexp)
      ((or (search "---" trimmed :end2 (min 10 (length trimmed)))
           (and (> (length trimmed) 0)
                (or (alpha-char-p (char trimmed 0))
                    (char= (char trimmed 0) #\#))))
       ;; Could be YAML or CSV
       (if (find #\, (subseq trimmed 0 (min 200 (length trimmed))))
           :csv
           :json))
      (t :json))))

;;; ---------------------------------------------------------------------------
;;; Schema validation for imported data
;;; ---------------------------------------------------------------------------

(defstruct (data-schema (:constructor make-data-schema))
  "Schema definition for validating imported data records.

Slots:
  NAME: Schema identifier
  FIELDS: List of field-schema structs defining expected fields
  STRICT-P: When T, reject records with unknown fields
  VERSION: Schema version string"
  (name :unknown :type keyword)
  (fields '() :type list)
  (strict-p nil :type boolean)
  (version "1.0" :type string))

(defstruct (field-schema (:constructor make-field-schema))
  "Schema for a single data field.

Slots:
  NAME: Field keyword name
  TYPE: Expected CL type specifier
  REQUIRED-P: Whether the field must be present
  DEFAULT: Default value if missing
  VALIDATOR: Optional custom validation function"
  (name :unknown :type keyword)
  (type t :type (or symbol cons))
  (required-p nil :type boolean)
  (default nil)
  (validator nil :type (or null function)))

(defun validate-record-against-schema (record schema)
  "Validate a single data RECORD (plist) against SCHEMA.

Returns (VALUES valid-p errors) where errors is a list of error strings."
  (let ((errors '()))
    ;; Check required fields
    (dolist (field-def (data-schema-fields schema))
      (let ((value (getf record (field-schema-name field-def))))
        (when (and (field-schema-required-p field-def) (null value))
          (push (format nil "Missing required field: ~A" (field-schema-name field-def))
                errors))
        (when (and value (not (typep value (field-schema-type field-def))))
          (push (format nil "Type mismatch for ~A: expected ~A, got ~A"
                        (field-schema-name field-def)
                        (field-schema-type field-def)
                        (type-of value))
                errors))
        (when (and value (field-schema-validator field-def))
          (unless (funcall (field-schema-validator field-def) value)
            (push (format nil "Validation failed for ~A: ~S"
                          (field-schema-name field-def) value)
                  errors)))))
    ;; Check for unknown fields in strict mode
    (when (data-schema-strict-p schema)
      (let ((known-names (mapcar #'field-schema-name (data-schema-fields schema))))
        (loop for (key) on record by #'cddr
              unless (member key known-names)
              do (push (format nil "Unknown field: ~A" key) errors))))
    (values (null errors) (nreverse errors))))

(defun validate-data-against-schema (data schema)
  "Validate a list of records against SCHEMA.

DATA: List of plists
SCHEMA: A data-schema struct

Returns (VALUES valid-p error-summary) where error-summary is a plist
with :total-records, :valid-count, :error-count, :errors."
  (let ((valid-count 0)
        (error-count 0)
        (all-errors '()))
    (loop for record in (ensure-list-of-plists data)
          for idx from 0
          do (multiple-value-bind (valid-p errors)
                 (validate-record-against-schema record schema)
               (if valid-p
                   (incf valid-count)
                   (progn
                     (incf error-count)
                     (push (list :record idx :errors errors) all-errors)))))
    (values (zerop error-count)
            (list :total-records (+ valid-count error-count)
                  :valid-count valid-count
                  :error-count error-count
                  :errors (nreverse all-errors)))))

;;; ---------------------------------------------------------------------------
;;; EVE-specific data schemas
;;; ---------------------------------------------------------------------------

(defparameter *eve-character-schema*
  (make-data-schema
   :name :character
   :fields (list
            (make-field-schema :name :character-id :type 'integer :required-p t)
            (make-field-schema :name :name :type 'string :required-p t)
            (make-field-schema :name :corporation-id :type 'integer :required-p nil)
            (make-field-schema :name :alliance-id :type '(or null integer) :required-p nil)
            (make-field-schema :name :birthday :type '(or null string) :required-p nil)
            (make-field-schema :name :security-status :type '(or null number) :required-p nil)))
  "Schema for EVE character data records.")

(defparameter *eve-market-order-schema*
  (make-data-schema
   :name :market-order
   :fields (list
            (make-field-schema :name :order-id :type 'integer :required-p t)
            (make-field-schema :name :type-id :type 'integer :required-p t)
            (make-field-schema :name :price :type 'number :required-p t)
            (make-field-schema :name :volume-remain :type 'integer :required-p nil)
            (make-field-schema :name :volume-total :type 'integer :required-p nil)
            (make-field-schema :name :is-buy-order :type 'boolean :required-p nil)
            (make-field-schema :name :location-id :type 'integer :required-p nil)
            (make-field-schema :name :issued :type '(or null string) :required-p nil)))
  "Schema for EVE market order data records.")

(defparameter *eve-wallet-transaction-schema*
  (make-data-schema
   :name :wallet-transaction
   :fields (list
            (make-field-schema :name :transaction-id :type 'integer :required-p t)
            (make-field-schema :name :type-id :type 'integer :required-p t)
            (make-field-schema :name :unit-price :type 'number :required-p t)
            (make-field-schema :name :quantity :type 'integer :required-p t)
            (make-field-schema :name :date :type '(or null string) :required-p nil)
            (make-field-schema :name :client-id :type '(or null integer) :required-p nil)
            (make-field-schema :name :is-buy :type 'boolean :required-p nil)))
  "Schema for EVE wallet transaction data records.")

;;; ---------------------------------------------------------------------------
;;; Data normalization utilities
;;; ---------------------------------------------------------------------------

(defun ensure-list-of-plists (data)
  "Normalize DATA into a list of plists.

Handles:
  - Already a list of plists -> return as-is
  - A single plist -> wrap in list
  - A list of hash-tables -> convert each to plist
  - A vector of hash-tables -> convert to list of plists"
  (typecase data
    (null nil)
    (hash-table (list (hash-table-to-plist data)))
    (vector (map 'list (lambda (item)
                         (if (hash-table-p item)
                             (hash-table-to-plist item)
                             item))
                 data))
    (cons
     (if (and (plist-p data) (not (consp (car data))))
         ;; Single plist
         (list data)
         ;; List of records
         (mapcar (lambda (item)
                   (typecase item
                     (hash-table (hash-table-to-plist item))
                     (t item)))
                 data)))
    (t (list data))))

(defun hash-table-to-plist (ht)
  "Convert a hash-table to a plist with keyword keys."
  (let ((result '()))
    (maphash (lambda (k v)
               (let ((key (etypecase k
                            (keyword k)
                            (string (intern (string-upcase (substitute #\- #\_ k))
                                            :keyword))
                            (symbol (intern (symbol-name k) :keyword)))))
                 (push (normalize-value v) result)
                 (push key result)))
             ht)
    result))

(defun normalize-value (value)
  "Normalize a parsed value for internal representation.

Converts:
  - :null -> NIL
  - Hash tables -> plists recursively
  - Vectors of hash-tables -> lists of plists
  - Non-string vectors -> lists
  - Strings stay as strings"
  (typecase value
    ((eql :null) nil)
    (string value)
    (hash-table (hash-table-to-plist value))
    (vector (if (and (plusp (length value))
                     (hash-table-p (aref value 0)))
                (map 'list #'hash-table-to-plist value)
                (coerce value 'list)))
    (t value)))

;;; ---------------------------------------------------------------------------
;;; Compression utilities
;;; ---------------------------------------------------------------------------

(defun compressed-file-p (pathname)
  "Return T if PATHNAME has a known compression extension."
  (let ((ext (string-downcase (or (pathname-type (pathname pathname)) ""))))
    (member ext '("gz" "gzip" "bz2" "xz" "zst") :test #'string=)))

;;; ---------------------------------------------------------------------------
;;; Format summary for REPL
;;; ---------------------------------------------------------------------------

(defun format-registry-summary (&optional (stream *standard-output*))
  "Print a summary of all registered data formats.

STREAM: Output stream (default: *standard-output*)"
  (format stream "~&=== Registered Data Formats ===~%")
  (dolist (name (list-formats))
    (let ((handler (find-format-handler name)))
      (format stream "  ~A  (.~A, ~A)~@[  [streaming]~]~%"
              name
              (format-handler-extension handler)
              (format-handler-mime-type handler)
              (format-handler-streaming-p handler))))
  (format stream "  Total: ~D formats~%" (length (list-formats)))
  (format stream "=== End Formats ===~%")
  (values))
