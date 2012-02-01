(defpackage #:sys.lap
  (:documentation "The system assembler.")
  (:use #:cl)
  (:export #:perform-assembly #:emit #:immediatep #:resolve-immediate #:*current-address*))

(in-package #:sys.lap)

(defvar *current-address* nil
  "Address of the current instruction.")
(defvar *machine-code* nil
  "Buffer containing emitted machine code.")
(defvar *symbol-table* nil
  "The current symbol table.")
(defvar *prev-symbol-table* nil)
(defvar *constant-pool* nil
  "The constant pool.")
(defvar *mc-end* nil)
(defvar *missing-symbols* nil)
(defvar *bytes-emitted* nil)

(defun emit (&rest bytes)
  "Emit bytes to the output stream."
  (dolist (i bytes)
    (check-type i (unsigned-byte 8))
    (incf *current-address*)
    (incf *bytes-emitted*)
    (vector-push-extend i *machine-code*)))

(defun perform-assembly (instruction-set code-list &key (base-address 0) (initial-symbols '()) &allow-other-keys)
  "Assemble a list of instructions, returning a u-b 8 vector of machine code,
a vector of constants and an alist of symbols & addresses."
  (do ((*constant-pool* (make-array 16
				    :fill-pointer 0
				    :adjustable t))
       (prev-bytes-emitted nil)
       (*bytes-emitted* 0)
       (failed-instructions 0 0)
       (*missing-symbols* '())
       (*mc-end* nil (+ base-address (length *machine-code*)))
       (*machine-code* nil)
       (*current-address* base-address base-address)
       (*symbol-table* nil)
       (*prev-symbol-table* (make-hash-table) *symbol-table*))
      ((eql prev-bytes-emitted *bytes-emitted*)
       (when *missing-symbols*
	 (error "Assembly failed. Missing symbols: ~S." *missing-symbols*))
       (values *machine-code*
	       *constant-pool*
	       (let ((alist '()))
		 (maphash (lambda (k v)
			    (push (cons k v) alist))
			  *symbol-table*)
		 alist)))
    (setf prev-bytes-emitted *bytes-emitted*
	  *bytes-emitted* 0
	  *machine-code* (make-array 128
				   :element-type '(unsigned-byte 8)
				   :fill-pointer 0
				   :adjustable t)
	  *symbol-table* (let ((hash-table (make-hash-table)))
			   (dolist (x initial-symbols)
			     (setf (gethash (first x) hash-table) (rest x)))
			   hash-table)
	  *missing-symbols* '())
    (dolist (i code-list)
      (etypecase i
	(symbol (when (gethash i *symbol-table*)
		  (cerror "Replace the existing symbol." "Duplicate symbol ~S." i))
		(setf (gethash i *symbol-table*) *current-address*))
	(cons (with-simple-restart (continue "Skip it.")
		(if (keywordp (first i))
		    (ecase (first i)
		      (:d8 (apply 'emit-d8 (rest i)))
		      (:d16/le (apply 'emit-d16/le (rest i)))
		      (:d32/le (apply 'emit-d32/le (rest i)))
		      (:d64/le (apply 'emit-d64/le (rest i))))
		    (let ((handler (gethash (first i) instruction-set)))
		      (if handler
			  (unless (funcall handler i)
			    (incf failed-instructions))
			  (error "Unrecognized instruction ~S." (first i)))))))))))

(defun emit-d8 (&rest args)
  (dolist (a args)
    (emit a)))

(defun emit-d16/le (&rest args)
  (dolist (a args)
    (check-type a (unsigned-byte 16))
    (emit (ldb (byte 8 0) a)
	  (ldb (byte 8 8) a))))

(defun emit-d32/le (&rest args)
  (dolist (a args)
    (check-type a (unsigned-byte 32))
    (emit (ldb (byte 8 0) a)
	  (ldb (byte 8 8) a)
	  (ldb (byte 8 16) a)
	  (ldb (byte 8 24) a))))

(defun emit-d64/le (&rest args)
  (dolist (a args)
    (check-type a (unsigned-byte 64))
    (emit (ldb (byte 8 0) a)
	  (ldb (byte 8 8) a)
	  (ldb (byte 8 16) a)
	  (ldb (byte 8 24) a)
	  (ldb (byte 8 32) a)
	  (ldb (byte 8 40) a)
	  (ldb (byte 8 48) a)
	  (ldb (byte 8 56) a))))

(defun immediatep (thing)
  "Test if THING is an immediate value."
  (or (symbolp thing)
      (integerp thing)))

(defun resolve-immediate (value)
  "Convert an immediate value to an integer."
  (etypecase value
    (cons (cond ((keywordp (first value))
		 (ecase (first value)
		   (:constant-address
		    (when *mc-end*
		      (+ (* (ceiling *mc-end* 16) 16)
			 (* (or (position (second value) *constant-pool*)
				(vector-push-extend (second value) *constant-pool*)) 8))))))
		(t (let ((args (mapcar #'resolve-immediate (rest value))))
		     (unless (member nil args)
		       (apply (first value) args))))))
    (symbol (let ((val (gethash value *symbol-table*))
		  (old-val (gethash value *prev-symbol-table*)))
	      (cond (val)
		    (old-val)
		    (t (pushnew value *missing-symbols*)
		       nil))))
    (integer value)))