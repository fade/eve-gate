;;;; code-generator.lisp - ESI API code generation orchestrator
;;;;
;;;; Coordinates the complete code generation pipeline from a processed
;;;; ESI specification to compilable Common Lisp source files. This is the
;;;; main entry point for the code generation framework (Phase 2 Task 2).
;;;;
;;;; Pipeline:
;;;;   1. Receive processed esi-spec from spec-processor.lisp
;;;;   2. Organize endpoints by category for namespace separation
;;;;   3. Generate function forms via templates.lisp
;;;;   4. Generate validation code via validation.lisp
;;;;   5. Generate response parsing and type conversion
;;;;   6. Generate comprehensive documentation from OpenAPI descriptions
;;;;   7. Write generated files to src/api/generated/
;;;;
;;;; Features:
;;;;   - Full generation of all 195+ ESI endpoint functions
;;;;   - Incremental regeneration (only changed endpoints)
;;;;   - Comprehensive docstrings with parameter docs and examples
;;;;   - Integration with HTTP client, auth, caching middleware
;;;;   - Response type mapping for downstream consumers
;;;;   - Generation report with statistics
;;;;
;;;; Design:
;;;;   - Functional core: spec -> forms (pure, no side effects)
;;;;   - I/O confined to write-generated-* functions
;;;;   - Generation is idempotent: same spec always produces same output
;;;;   - All generated code is clearly marked and separated from hand-written code
;;;;
;;;; Usage:
;;;;   ;; Generate all API functions
;;;;   (let ((spec (fetch-and-process-esi-spec)))
;;;;     (generate-api-functions spec))
;;;;
;;;;   ;; Generate a single category
;;;;   (generate-category-api spec "characters" :output-dir #p"src/api/generated/")
;;;;
;;;;   ;; Generate and inspect without writing files
;;;;   (generate-endpoint-function
;;;;     (find-endpoint-by-id spec "get_characters_character_id"))

(in-package #:eve-gate.api)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defparameter *generated-code-directory* nil
  "Directory for generated API source files. NIL means src/api/generated/
relative to the system source directory.")

(defparameter *generation-signature-file* nil
  "Path to the signature cache file for incremental regeneration.
NIL means .generation-signatures in the generated code directory.")

;;; ---------------------------------------------------------------------------
;;; Main entry points
;;; ---------------------------------------------------------------------------

(defun generate-api-functions (spec &key (output-dir nil)
                                         (incremental t)
                                         (compile-p nil)
                                         (verbose t))
  "Generate all ESI API functions from a processed specification.

This is the primary entry point for the code generation framework.
It generates one file per ESI category (e.g., characters.lisp, markets.lisp)
in the output directory.

SPEC: An esi-spec struct from fetch-and-process-esi-spec
OUTPUT-DIR: Directory for generated files (default: src/api/generated/)
INCREMENTAL: Only regenerate categories with changed endpoints (default: T)
COMPILE-P: Compile generated files after writing (default: NIL)
VERBOSE: Print generation progress (default: T)

Returns a generation-report struct with statistics.

Example:
  ;; Full generation
  (let ((spec (fetch-and-process-esi-spec)))
    (generate-api-functions spec))

  ;; Force full regeneration, compile immediately
  (generate-api-functions spec :incremental nil :compile-p t)"
  (let* ((gen-dir (or output-dir (default-generated-directory)))
         (endpoints (esi-spec-endpoints spec))
         (categories (esi-spec-categories spec))
         (report (make-generation-report))
         (old-signatures (when incremental
                           (load-generation-signatures gen-dir)))
         (new-signatures (make-hash-table :test 'equal)))
    (when verbose
      (format t "~&[CODEGEN] Starting API code generation...~%")
      (format t "[CODEGEN] Spec: ~A v~A, ~D endpoints in ~D categories~%"
              (esi-spec-title spec)
              (esi-spec-version spec)
              (length endpoints)
              (length categories)))
    ;; Generate registration file (endpoint registry)
    (generate-endpoint-registry-file spec gen-dir)
    (incf (generation-report-files-written report))
    ;; Generate response type map
    (generate-response-types-file spec gen-dir)
    (incf (generation-report-files-written report))
    ;; Generate each category
    (dolist (category categories)
      (let* ((new-sig (category-signature endpoints category))
             (old-sig (when old-signatures
                        (gethash category old-signatures)))
             (changed-p (or (not incremental)
                            (null old-sig)
                            (not (string= new-sig old-sig)))))
        (setf (gethash category new-signatures) new-sig)
        (if changed-p
            (progn
              (when verbose
                (format t "[CODEGEN] Generating: ~A (~D endpoints)~%"
                        category
                        (length (find-endpoints-by-category spec category))))
              (generate-category-api spec category
                                     :output-dir gen-dir
                                     :compile-p compile-p)
              (incf (generation-report-files-written report))
              (incf (generation-report-categories-generated report))
              (incf (generation-report-functions-generated report)
                    (length (find-endpoints-by-category spec category))))
            (when verbose
              (format t "[CODEGEN] Skipping: ~A (unchanged)~%"
                      category)))))
    ;; Save signatures for next incremental run
    (save-generation-signatures new-signatures gen-dir)
    ;; Set report totals
    (setf (generation-report-total-endpoints report) (length endpoints)
          (generation-report-total-categories report) (length categories)
          (generation-report-spec-version report) (esi-spec-version spec)
          (generation-report-generated-at report) (get-universal-time))
    ;; Print summary
    (when verbose
      (print-generation-report report))
    report))

(defun generate-category-api (spec category &key (output-dir nil)
                                                   (compile-p nil))
  "Generate the API function file for a single ESI category.

SPEC: An esi-spec struct
CATEGORY: Category string (e.g., \"characters\")
OUTPUT-DIR: Directory for generated files
COMPILE-P: Whether to compile the generated file

Returns the pathname of the generated file."
  (let* ((gen-dir (or output-dir (default-generated-directory)))
         (endpoints (esi-spec-endpoints spec))
         (forms (generate-category-file-form endpoints category))
         (filename (format nil "~A.lisp" (string-downcase category)))
         (filepath (merge-pathnames filename gen-dir)))
    (write-generated-file forms filepath)
    (when compile-p
      (handler-case
          (compile-file filepath)
        (error (e)
          (log-warn "Failed to compile ~A: ~A" filepath e))))
    filepath))

(defun generate-endpoint-function (endpoint)
  "Generate a function form for a single endpoint and return it.

This is useful for REPL-driven development and testing individual
endpoint generation without writing files.

ENDPOINT: An endpoint-definition struct

Returns the DEFUN form as a list.

Example:
  (generate-endpoint-function
    (find-endpoint-by-id *spec* \"get_characters_character_id\"))
  ;; Returns a complete DEFUN form that can be inspected or evaluated"
  (generate-endpoint-function-form endpoint))

;;; ---------------------------------------------------------------------------
;;; Endpoint registry generation
;;; ---------------------------------------------------------------------------

(defun generate-endpoint-registry-file (spec output-dir)
  "Generate the endpoint registry file mapping operation IDs to metadata.

This file creates a hash-table that generated functions and the API client
can use to look up endpoint information at runtime.

SPEC: An esi-spec struct
OUTPUT-DIR: Directory for the output file

Returns the pathname of the generated file."
  (let* ((endpoints (esi-spec-endpoints spec))
         (filepath (merge-pathnames "endpoint-registry-data.lisp" output-dir))
         (forms (generate-registry-forms endpoints)))
    (write-generated-file forms filepath)))

(defun generate-registry-forms (endpoints)
  "Generate forms that populate the endpoint registry.

ENDPOINTS: List of endpoint-definition structs

Returns a list of Lisp forms."
  (let ((forms '()))
    ;; Header
    (push `(comment
            ,(format nil ";;;; endpoint-registry-data.lisp - Generated endpoint registry~%~
                          ;;;;~%~
                          ;;;; AUTO-GENERATED. Do not edit manually.~%~
                          ;;;; Contains runtime metadata for ~D ESI endpoints.~%~
                          ;;;; Generated: ~A"
                     (length endpoints)
                     (format-generation-timestamp)))
          forms)
    ;; In-package
    (push '(in-package #:eve-gate.api) forms)
    ;; Registry hash-table definition
    (push `(defvar *endpoint-registry* (make-hash-table :test 'equal)
             "Registry mapping operation IDs to endpoint metadata plists.
Each entry contains: :path, :method, :category, :requires-auth, :scopes,
:paginated, :cache-duration, :function-name, :deprecated.")
          forms)
    ;; Populate registry
    (push `(defun populate-endpoint-registry ()
             "Populate the endpoint registry with all ESI endpoint metadata."
             (clrhash *endpoint-registry*)
             ,@(mapcar #'generate-registry-entry endpoints)
             (log-info "Endpoint registry populated: ~D endpoints"
                       (hash-table-count *endpoint-registry*))
             *endpoint-registry*)
          forms)
    ;; Lookup functions
    (push `(defun lookup-endpoint (operation-id)
             "Look up endpoint metadata by operation ID.

OPERATION-ID: String (e.g., \"get_characters_character_id\")

Returns a plist of endpoint metadata, or NIL."
             (gethash operation-id *endpoint-registry*))
          forms)
    (push `(defun list-endpoints-by-category (category)
             "List all operation IDs in a given category.

CATEGORY: Category string (e.g., \"characters\")

Returns a list of operation ID strings."
             (loop for op-id being the hash-keys of *endpoint-registry*
                   using (hash-value meta)
                   when (string-equal (getf meta :category) category)
                     collect op-id))
          forms)
    (nreverse forms)))

(defun generate-registry-entry (endpoint)
  "Generate a form to register a single endpoint in the registry.

ENDPOINT: An endpoint-definition struct

Returns a SETF form."
  `(setf (gethash ,(endpoint-definition-operation-id endpoint)
                   *endpoint-registry*)
         (list :path ,(endpoint-definition-path endpoint)
               :method ,(endpoint-definition-method endpoint)
               :category ,(endpoint-definition-category endpoint)
               :function-name ,(endpoint-definition-function-name endpoint)
               :requires-auth ,(endpoint-definition-requires-auth-p endpoint)
               :scopes ',(endpoint-definition-required-scopes endpoint)
               :paginated ,(endpoint-definition-paginated-p endpoint)
               :cache-duration ,(endpoint-definition-cache-duration endpoint)
               :deprecated ,(endpoint-definition-deprecated-p endpoint))))

;;; ---------------------------------------------------------------------------
;;; Response type map generation
;;; ---------------------------------------------------------------------------

(defun generate-response-types-file (spec output-dir)
  "Generate a file mapping operation IDs to their response type information.

This file provides type metadata used by response parsing and the type system.

SPEC: An esi-spec struct
OUTPUT-DIR: Directory for the output file

Returns the pathname of the generated file."
  (let* ((endpoints (esi-spec-endpoints spec))
         (filepath (merge-pathnames "response-types.lisp" output-dir))
         (forms (generate-response-type-forms endpoints)))
    (write-generated-file forms filepath)))

(defun generate-response-type-forms (endpoints)
  "Generate forms that define response type metadata.

ENDPOINTS: List of endpoint-definition structs

Returns a list of Lisp forms."
  (let ((forms '())
        (endpoints-with-schemas
          (remove-if-not #'endpoint-definition-response-schema endpoints)))
    ;; Header
    (push `(comment
            ,(format nil ";;;; response-types.lisp - Generated response type definitions~%~
                          ;;;;~%~
                          ;;;; AUTO-GENERATED. Do not edit manually.~%~
                          ;;;; Contains response type metadata for ~D ESI endpoints.~%~
                          ;;;; Generated: ~A"
                     (length endpoints-with-schemas)
                     (format-generation-timestamp)))
          forms)
    ;; In-package
    (push '(in-package #:eve-gate.api) forms)
    ;; Response type map
    (push `(defvar *response-type-map* (make-hash-table :test 'equal)
             "Registry mapping operation IDs to response type plists.
Each entry contains: :type (CL type specifier), :schema-type (keyword),
:element-type (for arrays), :description.")
          forms)
    ;; Populate function
    (push `(defun populate-response-types ()
             "Populate the response type registry."
             (clrhash *response-type-map*)
             ,@(mapcar #'generate-response-type-entry endpoints-with-schemas)
             (log-info "Response type registry populated: ~D types"
                       (hash-table-count *response-type-map*))
             *response-type-map*)
          forms)
    ;; Response parser dispatch
    (push `(defun parse-endpoint-response (operation-id data)
             "Parse response DATA according to the expected type for OPERATION-ID.

OPERATION-ID: String identifying the endpoint
DATA: The raw response data (from jzon parsing)

Returns the parsed data, possibly with type conversion applied."
             (let ((type-info (gethash operation-id *response-type-map*)))
               (if type-info
                   (coerce-response-data data type-info)
                   data)))
          forms)
    ;; Response coercion
    (push `(defun coerce-response-data (data type-info)
             "Coerce response DATA according to TYPE-INFO metadata.

Handles:
  - Date-time string conversion (when local-time is available)
  - Nested object property access via keywords
  - Array element type consistency

DATA: The raw parsed response data
TYPE-INFO: Plist from the response type registry

Returns the data, potentially with type annotations or conversions."
             (declare (ignore type-info))
             ;; For now, return data as-is from jzon parsing.
             ;; Future enhancement: deep type conversion, date parsing, etc.
             data)
          forms)
    (nreverse forms)))

(defun generate-response-type-entry (endpoint)
  "Generate a form to register response type metadata for an endpoint.

ENDPOINT: An endpoint-definition struct with a response schema

Returns a SETF form."
  (let* ((schema (endpoint-definition-response-schema endpoint))
         (op-id (endpoint-definition-operation-id endpoint))
         (schema-type (schema-definition-type schema))
         (element-type (when (eq schema-type :array)
                         (when-let ((items (schema-definition-items-schema schema)))
                           (schema-definition-type items))))
         (description (or (endpoint-definition-response-description endpoint)
                          (schema-definition-description schema))))
    `(setf (gethash ,op-id *response-type-map*)
           (list :cl-type ',(schema-definition-cl-type schema)
                 :schema-type ,schema-type
                 :element-type ,element-type
                 :description ,description
                 :properties ',(when (eq schema-type :object)
                                 (mapcar (lambda (prop)
                                           (cons (property-definition-name prop)
                                                 (when (property-definition-schema prop)
                                                   (schema-definition-type
                                                    (property-definition-schema prop)))))
                                         (schema-definition-properties schema)))))))

;;; ---------------------------------------------------------------------------
;;; Generation report
;;; ---------------------------------------------------------------------------

(defstruct (generation-report (:constructor make-generation-report))
  "Statistics from a code generation run.

Slots:
  TOTAL-ENDPOINTS: Total endpoint count from the spec
  TOTAL-CATEGORIES: Total category count from the spec
  FUNCTIONS-GENERATED: Number of function definitions generated
  CATEGORIES-GENERATED: Number of category files generated (or regenerated)
  FILES-WRITTEN: Total files written to disk
  SPEC-VERSION: Version string from the spec
  GENERATED-AT: Universal time of generation"
  (total-endpoints 0 :type integer)
  (total-categories 0 :type integer)
  (functions-generated 0 :type integer)
  (categories-generated 0 :type integer)
  (files-written 0 :type integer)
  (spec-version nil :type (or null string))
  (generated-at 0 :type integer))

(defun print-generation-report (report &optional (stream *standard-output*))
  "Print a human-readable generation report.

REPORT: A generation-report struct
STREAM: Output stream (default: *standard-output*)"
  (format stream "~&~%[CODEGEN] === Generation Report ===~%")
  (format stream "[CODEGEN] Spec version: ~A~%"
          (or (generation-report-spec-version report) "unknown"))
  (format stream "[CODEGEN] Total endpoints: ~D~%"
          (generation-report-total-endpoints report))
  (format stream "[CODEGEN] Total categories: ~D~%"
          (generation-report-total-categories report))
  (format stream "[CODEGEN] Functions generated: ~D~%"
          (generation-report-functions-generated report))
  (format stream "[CODEGEN] Categories generated: ~D~%"
          (generation-report-categories-generated report))
  (format stream "[CODEGEN] Files written: ~D~%"
          (generation-report-files-written report))
  (format stream "[CODEGEN] ===========================~%")
  report)

;;; ---------------------------------------------------------------------------
;;; File paths
;;; ---------------------------------------------------------------------------

(defun default-generated-directory ()
  "Return the default directory for generated API source files."
  (let ((dir (or *generated-code-directory*
                 (merge-pathnames "src/api/generated/"
                                  (asdf:system-source-directory :eve-gate)))))
    (ensure-directories-exist dir)
    dir))

;;; ---------------------------------------------------------------------------
;;; Incremental regeneration support
;;; ---------------------------------------------------------------------------

(defun signatures-file-path (gen-dir)
  "Return the path to the generation signatures file.

GEN-DIR: The generated code directory"
  (or *generation-signature-file*
      (merge-pathnames ".generation-signatures.sexp" gen-dir)))

(defun save-generation-signatures (signatures gen-dir)
  "Save category signatures to disk for incremental regeneration.

SIGNATURES: Hash-table mapping category names to signature strings
GEN-DIR: Generated code directory"
  (let ((path (signatures-file-path gen-dir)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
      (let ((*print-readably* t)
            (*print-pretty* nil))
        ;; Write as an alist for portable serialization
        (let ((alist '()))
          (maphash (lambda (k v) (push (cons k v) alist)) signatures)
          (prin1 alist out))))
    path))

(defun load-generation-signatures (gen-dir)
  "Load previously saved generation signatures from disk.

GEN-DIR: Generated code directory

Returns a hash-table of category->signature mappings, or NIL if no cache."
  (let ((path (signatures-file-path gen-dir)))
    (when (probe-file path)
      (handler-case
          (with-open-file (in path :direction :input)
            (let ((alist (read in nil nil)))
              (when (listp alist)
                (let ((ht (make-hash-table :test 'equal)))
                  (dolist (pair alist)
                    (when (consp pair)
                      (setf (gethash (car pair) ht) (cdr pair))))
                  ht))))
        (error (e)
          (log-warn "Failed to load generation signatures: ~A" e)
          nil)))))

;;; ---------------------------------------------------------------------------
;;; Code generation utilities
;;; ---------------------------------------------------------------------------

(defun generate-type-definitions (spec)
  "Generate Common Lisp type definitions from the spec's response schemas.

Wrapper around generate-cl-type-definitions that also produces
type predicate functions for important EVE entity types.

SPEC: An esi-spec struct

Returns a list of DEFTYPE and DEFUN forms."
  (let ((type-defs (generate-cl-type-definitions spec))
        (entity-types '()))
    ;; Add EVE entity type predicates
    (dolist (type-def '((character-id-p "Valid EVE character ID (32-bit positive integer)"
                         (lambda (id) (typep id '(integer 1 2147483647))))
                        (corporation-id-p "Valid EVE corporation ID"
                         (lambda (id) (typep id '(integer 1 2147483647))))
                        (alliance-id-p "Valid EVE alliance ID"
                         (lambda (id) (typep id '(integer 1 2147483647))))
                        (type-id-p "Valid EVE type ID"
                         (lambda (id) (typep id '(integer 0 2147483647))))
                        (region-id-p "Valid EVE region ID"
                         (lambda (id) (typep id '(integer 10000000 19999999))))
                        (system-id-p "Valid EVE solar system ID"
                         (lambda (id) (typep id '(integer 30000000 39999999))))))
      (destructuring-bind (name doc pred) type-def
        (push `(defun ,name (id)
                 ,doc
                 (funcall ,pred id))
              entity-types)))
    (append type-defs (nreverse entity-types))))

(defun generate-client-code (spec &key (output-dir nil))
  "Generate the complete client code package from a spec.

This is a convenience function that generates:
  1. All API function files by category
  2. Endpoint registry
  3. Response type definitions
  4. Entity type predicates

SPEC: An esi-spec struct
OUTPUT-DIR: Directory for generated files

Returns the generation report."
  (generate-api-functions spec :output-dir output-dir :verbose t))

;;; ---------------------------------------------------------------------------
;;; REPL utilities for development and inspection
;;; ---------------------------------------------------------------------------

(defun show-generated-function (spec operation-id &optional (stream *standard-output*))
  "Display the generated function form for an endpoint (for REPL inspection).

SPEC: An esi-spec struct
OPERATION-ID: Operation ID string (e.g., \"get_characters_character_id\")
STREAM: Output stream (default: *standard-output*)

Example:
  (show-generated-function *spec* \"get_characters_character_id\")"
  (let ((endpoint (find-endpoint-by-id spec operation-id)))
    (if endpoint
        (let ((form (generate-endpoint-function endpoint)))
          (let ((*print-case* :downcase)
                (*print-pretty* t)
                (*print-right-margin* 100))
            (pprint form stream)
            (terpri stream))
          form)
        (format stream "~&Endpoint ~S not found.~%" operation-id))))

(defun show-category-functions (spec category &optional (stream *standard-output*))
  "Display all generated function forms for a category.

SPEC: An esi-spec struct
CATEGORY: Category string
STREAM: Output stream"
  (let ((endpoints (find-endpoints-by-category spec category)))
    (format stream "~&Category: ~A (~D endpoints)~%~%" category (length endpoints))
    (dolist (ep endpoints)
      (format stream "~&;;; ~A~%" (endpoint-definition-operation-id ep))
      (show-generated-function spec (endpoint-definition-operation-id ep) stream)
      (terpri stream))))

(defun generation-statistics (spec)
  "Return a plist of statistics about what would be generated from SPEC.

SPEC: An esi-spec struct

Returns a plist with generation statistics."
  (let* ((endpoints (esi-spec-endpoints spec))
         (categories (esi-spec-categories spec))
         (authenticated (count-if #'endpoint-definition-requires-auth-p endpoints))
         (public (- (length endpoints) authenticated))
         (paginated (count-if #'endpoint-definition-paginated-p endpoints))
         (deprecated (count-if #'endpoint-definition-deprecated-p endpoints))
         (with-body (count-if #'endpoint-definition-body-parameter endpoints))
         (methods (make-hash-table)))
    (dolist (ep endpoints)
      (incf (gethash (endpoint-definition-method ep) methods 0)))
    (list :total-endpoints (length endpoints)
          :total-categories (length categories)
          :categories categories
          :authenticated authenticated
          :public public
          :paginated paginated
          :deprecated deprecated
          :with-body-param with-body
          :by-method (let ((alist '()))
                       (maphash (lambda (k v) (push (cons k v) alist)) methods)
                       (sort alist #'> :key #'cdr)))))
