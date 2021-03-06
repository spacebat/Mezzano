;;;; Copyright (c) 2011-2015 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :sys.int)

(setf sys.lap-x86:*function-reference-resolver* #'function-reference)

(defun proclaim (declaration-specifier)
  (case (first declaration-specifier)
    (special (dolist (var (rest declaration-specifier))
               (setf (system:symbol-mode var) :special)))
    (constant (dolist (var (rest declaration-specifier))
                (setf (system:symbol-mode var) :constant)))
    (inline
     (dolist (name (rest declaration-specifier))
       (multiple-value-bind (sym indicator)
           (if (symbolp name)
               (values name 'inline-mode)
               (values (second name) 'setf-inline-mode))
         (setf (get sym indicator) t))))
    (notinline
     (dolist (name (rest declaration-specifier))
       (multiple-value-bind (sym indicator)
           (if (symbolp name)
               (values name 'inline-mode)
               (values (second name) 'setf-inline-mode))
         (setf (get sym indicator) nil))))))

(defun system:symbol-mode (symbol)
  (svref #(nil :special :constant :symbol-macro)
         (ldb (byte 2 8) (%array-like-ref-unsigned-byte-64 symbol -1))))

(defun (setf system:symbol-mode) (value symbol)
  (setf (ldb (byte 2 8) (%array-like-ref-unsigned-byte-64 symbol -1))
        (ecase value
          ((nil) +symbol-mode-nil+)
          ((:special) +symbol-mode-special+)
          ((:constant) +symbol-mode-constant+)
          ((:symbol-macro) +symbol-mode-symbol-macro+)))
  value)

(defun variable-information (symbol)
  (symbol-mode symbol))

(defun sys.c::function-inline-info (name)
  (multiple-value-bind (sym mode-name form-name)
      (if (symbolp name)
          (values name 'inline-mode 'inline-form)
          (values (second name) 'setf-inline-mode 'setf-inline-form))
    (values (get sym mode-name)
            (get sym form-name))))

;;; Turn (APPLY fn arg) into (%APPLY fn arg), bypassing APPLY's
;;; rest-list generation in the single arg case.
;;; Would be nice to turn (APPLY fn args...) into (%APPLY fn (LIST* args...)),
;;; but that would cause callers to cons when they didn't before. Don't
;;; know if that's a problem... Need DX-LIST*.
;;; Or better APPLY implementation.
(define-compiler-macro apply (&whole whole function arg &rest more-args)
  (if more-args
      whole
      `(%apply (%coerce-to-callable ,function) ,arg)))

(defun apply (function arg &rest more-args)
  (declare (dynamic-extent more-args))
  (check-type function (or function symbol) "a function-designator")
  (when (symbolp function)
    (setf function (symbol-function function)))
  (cond (more-args
         ;; Convert (... (final-list ...)) to (... final-list...)
         (do* ((arg-list (cons arg more-args))
               (i arg-list (cdr i)))
              ((null (cddr i))
               (setf (cdr i) (cadr i))
               (%apply function arg-list))))
        (t (%apply function arg))))

;;; Support function for APPLY.
;;; Takes a function & a list of arguments.
;;; The function must be a function, but type-checking
;;; will be performed on the argument list.
;;; FIXME: should enforce CALL-ARGUMENTS-LIMIT.
(define-lap-function %apply ()
  (sys.lap-x86:push :rbp)
  (:gc :no-frame :layout #*0)
  (sys.lap-x86:mov64 :rbp :rsp)
  (:gc :frame)
  ;; Function goes in RBX.
  (sys.lap-x86:mov64 :rbx :r8)
  ;; Argument count.
  (sys.lap-x86:xor32 :ecx :ecx)
  ;; Words pushed for alignment.
  (sys.lap-x86:xor32 :edi :edi)
  ;; Check for no arguments.
  (sys.lap-x86:cmp64 :r9 nil)
  (sys.lap-x86:je do-call)
  ;; Unpack the list.
  ;; Known to have at least one cons, so we can drop directly into the body.
  (sys.lap-x86:mov64 :r13 :r9)
  unpack-loop
  (:gc :frame :pushed-values-register :rcx)
  ;; Typecheck list, part 2. consp
  (sys.lap-x86:mov8 :al :r13l)
  (sys.lap-x86:and8 :al #b1111)
  (sys.lap-x86:cmp8 :al #.+tag-cons+)
  (sys.lap-x86:jne list-type-error)
  ;; Push car & increment arg count
  (sys.lap-x86:push (:car :r13))
  (:gc :frame :pushed-values-register :rcx :pushed-values 1)
  (sys.lap-x86:add32 :ecx #.(ash 1 +n-fixnum-bits+)) ; fixnum 1
  (:gc :frame :pushed-values-register :rcx)
  ;; Advance.
  (sys.lap-x86:mov64 :r13 (:cdr :r13))
  ;; Typecheck list, part 1. null
  (sys.lap-x86:cmp64 :r13 nil)
  (sys.lap-x86:jne unpack-loop)
  ;; Arguments have been pushed on the stack in reverse.
  ;; Ensure the stack is misaligned.
  ;; Misalign because 5 registers will be popped off, leaving
  ;; the stack correctly aligned.
  (sys.lap-x86:test64 :rsp 8)
  (sys.lap-x86:jnz stack-aligned)
  ;; Don't push anything extra if there are 5 or fewer args.
  ;; They will all be popped off.
  (sys.lap-x86:cmp32 :ecx #.(ash 5 +n-fixnum-bits+)) ; fixnum 5
  (sys.lap-x86:jbe stack-aligned)
  ;; Reversing will put this at the end of the stack, out of the way.
  (sys.lap-x86:push 0)
  (:gc :frame :pushed-values-register :rcx :pushed-values 1)
  (sys.lap-x86:add32 :ecx #.(ash 1 +n-fixnum-bits+)) ; fixnum 1
  (:gc :frame :pushed-values-register :rcx)
  (sys.lap-x86:add32 :edi #.(ash 1 +n-fixnum-bits+)) ; fixnum 1
  stack-aligned
  ;; RCX = n arguments. (fixnum)
  ;; RDX = left offset, RAX = right offset.
  (sys.lap-x86:lea32 :eax (:ecx #.(ash -1 +n-fixnum-bits+)))
  (sys.lap-x86:shr32 :eax #.+n-fixnum-bits+)
  (sys.lap-x86:shl32 :eax 3) ; * 8
  (sys.lap-x86:xor32 :edx :edx)
  (sys.lap-x86:jmp reverse-test)
  reverse-loop
  ;; Swap stack+rax & stack+rdx
  (sys.lap-x86:mov64 :r8 (:rsp :rax))
  (sys.lap-x86:mov64 :r9 (:rsp :rdx))
  (sys.lap-x86:mov64 (:rsp :rax) :r9)
  (sys.lap-x86:mov64 (:rsp :rdx) :r8)
  ;; Advance offsets.
  (sys.lap-x86:add32 :edx 8)
  (sys.lap-x86:sub32 :eax 8)
  reverse-test
  ;; Stop when RDX > RAX.
  (sys.lap-x86:cmp32 :eax :edx)
  (sys.lap-x86:ja reverse-loop)
  ;; Drop the word pushed for alignment (if any).
  (sys.lap-x86:sub32 :ecx :edi)
  ;; Put arguments into registers.
  ;; Always at least one argument by this point.
  (sys.lap-x86:pop :r8)
  (:gc :frame :pushed-values-register :rcx :pushed-values -1)
  (sys.lap-x86:cmp32 :ecx #.(ash 1 +n-fixnum-bits+))
  (sys.lap-x86:je do-call)
  (sys.lap-x86:pop :r9)
  (:gc :frame :pushed-values-register :rcx :pushed-values -2)
  (sys.lap-x86:cmp32 :ecx #.(ash 2 +n-fixnum-bits+))
  (sys.lap-x86:je do-call)
  (sys.lap-x86:pop :r10)
  (:gc :frame :pushed-values-register :rcx :pushed-values -3)
  (sys.lap-x86:cmp32 :ecx #.(ash 3 +n-fixnum-bits+))
  (sys.lap-x86:je do-call)
  (sys.lap-x86:pop :r11)
  (:gc :frame :pushed-values-register :rcx :pushed-values -4)
  (sys.lap-x86:cmp32 :ecx #.(ash 4 +n-fixnum-bits+))
  (sys.lap-x86:je do-call)
  (sys.lap-x86:pop :r12)
  (:gc :frame :pushed-values-register :rcx :pushed-values -5)
  ;; Everything is ready. Call the function!
  do-call
  (sys.lap-x86:call (:rbx #.(+ (- sys.int::+tag-object+) 8)))
  (:gc :frame)
  ;; Finish up & return.
  (sys.lap-x86:leave)
  (:gc :no-frame)
  (sys.lap-x86:ret)
  ;; R8 = function, R9 = arg-list.
  ;; (raise-type-error arg-list 'proper-list)
  list-type-error
  (:gc :frame)
  (sys.lap-x86:mov64 :r8 :r9)
  (sys.lap-x86:mov64 :r9 (:constant proper-list))
  (sys.lap-x86:mov64 :r13 (:function raise-type-error))
  (sys.lap-x86:mov32 :ecx #.(ash 2 +n-fixnum-bits+)) ; fixnum 2
  (sys.lap-x86:call (:r13 #.(+ (- sys.int::+tag-object+) 8 (* sys.int::+fref-entry-point+ 8))))
  (sys.lap-x86:ud2))

(defun symbol-tls-slot (symbol)
  (check-type symbol symbol)
  (let ((slot (ldb (byte 16 10) (sys.int::%array-like-ref-unsigned-byte-64 symbol -1))))
    (if (zerop slot) nil slot)))

(defun funcall (function &rest arguments)
  (declare (dynamic-extent arguments))
  (apply function arguments))

(defun values (&rest values)
  (declare (dynamic-extent values))
  (values-list values))

(defun constantly (value)
  (lambda (&rest arguments)
    (declare (ignore arguments))
    value))

(defun macro-function (symbol &optional env)
  (dolist (e env
           (get symbol '%macro-function))
    (when (eql (first e) :macros)
      (let ((fn (assoc symbol (rest e))))
        (when fn (return (cdr fn)))))))

(defun (setf macro-function) (value symbol &optional env)
  (when env
    (error "TODO: (Setf Macro-function) in environment."))
  (setf (symbol-function symbol) (lambda (&rest r)
                                   (declare (ignore r))
                                   (error 'undefined-function :name symbol))
        (get symbol '%macro-function) value))

(defun compiler-macro-function (name &optional environment)
  (multiple-value-bind (sym indicator)
      (if (symbolp name)
          (values name '%compiler-macro-function)
          (values (second name) '%setf-compiler-macro-function))
    (get sym indicator)))

(defun (setf compiler-macro-function) (value name &optional environment)
  (multiple-value-bind (sym indicator)
      (if (symbolp name)
          (values name '%compiler-macro-function)
          (values (second name) '%setf-compiler-macro-function))
    (setf (get sym indicator) value)))

;;; Calls to these functions are generated by the compiler to
;;; signal errors.
(defun raise-undefined-function (invoked-through &rest args)
  (error 'undefined-function :name (function-reference-name invoked-through)))

(defun raise-unbound-error (symbol)
  (error 'unbound-variable :name symbol))

(defun raise-type-error (datum expected-type)
  (error 'type-error :datum datum :expected-type expected-type))

(defun raise-invalid-argument-error ()
  (error 'invalid-arguments))

(defun raise-stack-alignment-error ()
  (error "Stack was misaligned."))

(defun raise-bounds-error (array index)
  (error "Index ~D out of bounds for array ~S." index array))

(defun list (&rest args)
  args)

(defun copy-list-in-area (list &optional area)
  (do* ((result (cons nil nil))
        (tail result)
        (l list (cdr l)))
       ((null l)
        (cdr result))
    (setf (cdr tail) (cons-in-area (car l) nil area)
          tail (cdr tail))))

(defun copy-list (list)
  (copy-list-in-area list))

;;; Will be overriden later in the init process.
(defun funcallable-instance-lambda-expression (function)
  (values nil t nil))
(defun funcallable-instance-debug-info (function)
  nil)
(defun funcallable-instance-compiled-function-p (function)
  t)

(defun function-name (function)
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (info (memref-unsigned-byte-64 address 0)))
    (ecase (%object-tag function)
      (#.+object-tag-function+ ;; Regular function. First entry in the constant pool.
       (memref-t address (* (logand (ash info -16) #xFFFF) 2)))
      (#.+object-tag-closure+ ;; Closure.
       (function-name (%array-like-ref-t function 1)))
      (#.+object-tag-funcallable-instance+
       (multiple-value-bind (lambda closurep name)
           (funcallable-instance-lambda-expression function)
         (declare (ignore lambda closurep))
         name)))))

(defun function-lambda-expression (function)
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (info (memref-unsigned-byte-64 address 0)))
    (ecase (%object-tag function)
      (#.+object-tag-function+ ;; Regular function. First entry in the constant pool.
       (values nil nil (memref-t address (* (logand (ash info -16) #xFFFF) 2))))
      (#.+object-tag-closure+ ;; Closure.
       (values nil t (function-name (%array-like-ref-t function 1))))
      (#.+object-tag-funcallable-instance+
       (funcallable-instance-lambda-expression function)))))

(defun function-debug-info (function)
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (info (memref-unsigned-byte-64 address 0)))
    (ecase (%object-tag function)
      (#.+object-tag-function+ ;; Regular function. second entry in the constant pool.
       (memref-t address (1+ (* (logand (ash info -16) #xFFFF) 2))))
      (#.+object-tag-closure+ ;; Closure.
       (function-debug-info (%array-like-ref-t function 1)))
      (#.+object-tag-funcallable-instance+
       (funcallable-instance-debug-info function)))))

(defun funcallable-std-instance-p (object)
  (and (functionp object)
       (eql (%object-tag object)
            +object-tag-funcallable-instance+)))

(defun funcallable-std-instance-function (funcallable-instance)
  (assert (funcallable-std-instance-p funcallable-instance) (funcallable-instance))
  (%array-like-ref-t funcallable-instance 4))
(defun (setf funcallable-std-instance-function) (value funcallable-instance)
  (check-type value function)
  (assert (funcallable-std-instance-p funcallable-instance) (funcallable-instance))
  (let ((entry-point (%array-like-ref-unsigned-byte-64 value 0)))
    ;; Fixme: need to do this atomically (use cmpxchg16b, like the fref code)
    ;; Must update entry-point first to avoid old function from being gc'd away.
    (setf (%array-like-ref-unsigned-byte-64 funcallable-instance 3) entry-point
          (%array-like-ref-t funcallable-instance 4) value)))

(defun funcallable-std-instance-class (funcallable-instance)
  (assert (funcallable-std-instance-p funcallable-instance) (funcallable-instance))
  (%array-like-ref-t funcallable-instance 5))
(defun (setf funcallable-std-instance-class) (value funcallable-instance)
  (assert (funcallable-std-instance-p funcallable-instance) (funcallable-instance))
  (setf (%array-like-ref-t funcallable-instance 5) value))

(defun funcallable-std-instance-slots (funcallable-instance)
  (assert (funcallable-std-instance-p funcallable-instance) (funcallable-instance))
  (%array-like-ref-t funcallable-instance 6))
(defun (setf funcallable-std-instance-slots) (value funcallable-instance)
  (assert (funcallable-std-instance-p funcallable-instance) (funcallable-instance))
  (setf (%array-like-ref-t funcallable-instance 6) value))

(defun compiled-function-p (object)
  (when (functionp object)
    (ecase (%object-tag object)
      ((#.+object-tag-function+
        #.+object-tag-closure+)
       t)
      (#.+object-tag-funcallable-instance+
       (funcallable-instance-compiled-function-p object)))))

(deftype compiled-function ()
  '(satisfies compiled-function-p))

;;; Implementations of DEFUN/etc, the cross-compiler defines these as well.

(defun %defmacro (name function &optional lambda-list)
  (setf (get name 'macro-lambda-list) lambda-list)
  (setf (macro-function name) function))

(defun %compiler-defun (name source-lambda)
  "Compile-time defun code. Store the inline form if required."
  (multiple-value-bind (sym mode-name form-name)
      (if (symbolp name)
          (values name 'inline-mode 'inline-form)
          (values (second name) 'setf-inline-mode 'setf-inline-form))
    (when (or (get sym mode-name)
              (get sym form-name))
      (setf (get sym form-name) source-lambda)))
  nil)

(defun %defun (name lambda)
  (setf (fdefinition name) lambda)
  name)

(defun %defstruct (structure-type)
  (setf (get (structure-name structure-type) 'structure-type) structure-type))

(defun %defconstant (name value &optional docstring)
  (proclaim `(special ,name))
  (setf (symbol-value name) value)
  (proclaim `(constant ,name))
  name)

;;; Function references, FUNCTION, et al.

(defun make-function-reference (name)
  (let ((fref (%allocate-array-like +object-tag-function-reference+ 4 0 :wired)))
    (setf (%array-like-ref-t fref +fref-name+) name
          (function-reference-function fref) nil)
    fref))

(defun function-reference (name)
  "Convert a function name to a function reference."
  ;; FIXME: lock here.
  (cond ((symbolp name)
         (let ((fref (symbol-fref name)))
           (unless fref
             (setf fref (make-function-reference name)
                   (symbol-fref name) fref))
           fref))
	((and (consp name)
	      (= (list-length name) 2)
	      (eql (first name) 'setf)
	      (symbolp (second name)))
	 (let ((fref (get (second name) 'setf-fref)))
	   (unless fref
	     (setf fref (make-function-reference name)
		   (get (second name) 'setf-fref) fref))
           fref))
	(t (error "Invalid function name ~S." name))))

(defun function-reference-p (object)
  (and (eql (%tag-field object) +tag-object+)
       (eql (%object-tag object) +object-tag-function-reference+)))

(deftype function-reference ()
  '(satisfies function-reference-p))

(defun function-reference-name (fref)
  (check-type fref function-reference)
  (%array-like-ref-t fref +fref-name+))

(defun function-reference-function (fref)
  (check-type fref function-reference)
  (let ((fn (%array-like-ref-t fref +fref-function+)))
    (if (%undefined-function-p fn)
        nil
        fn)))

(defun (setf function-reference-function) (value fref)
  "Update the function & entry-point fields of a function-reference.
VALUE may be nil to make the fref unbound."
  (check-type value (or function null))
  (check-type fref function-reference)
  (multiple-value-bind (new-fn new-entry-point)
      (cond
        ((not value)
         ;; Use the undefined function trampoline.
         ;; This must be stored in function slot so the closure-trampoline
         ;; works correctly.
         (values (%undefined-function)
                 (%array-like-ref-t (%undefined-function) 0)))
        ((eql (%object-tag value) +object-tag-closure+)
         ;; Use the closure trampoline.
         (values value
                 (%array-like-ref-t (%closure-trampoline) 0)))
        (t ;; Normal call.
         (values value
                 (%array-like-ref-t value 0))))
    ;; Atomically update both values.
    ;; Functions is followed by entry point.
    ;; A 128-byte store would work instead of a CAS, but it needs to be atomic.
    ;; Defer the GC over the CAS, it does bad things to registers.
    (mezzano.supervisor:with-gc-deferred
      (let ((old-1 (%array-like-ref-t fref +fref-function+))
            (old-2 (%array-like-ref-t fref +fref-entry-point+)))
        ;; Don't bother CASing in a loop. If another CPU beats us, then it as if
        ;; this write succeeded, but was immediately overwritten.
        (%dcas-array-like fref +fref-function+
                          old-1 old-2
                          new-fn new-entry-point))))
  value)

(defun fdefinition (name)
  (or (function-reference-function (function-reference name))
      (error 'undefined-function :name name)))

(defun (setf fdefinition) (value name)
  (check-type value function)
  (setf (function-reference-function (function-reference name)) value))

(defun fboundp (name)
  (not (null (function-reference-function (function-reference name)))))

(defun fmakunbound (name)
  (setf (function-reference-function (function-reference name)) nil)
  name)

(defun symbol-function (symbol)
  (check-type symbol symbol)
  (fdefinition symbol))

(defun (setf symbol-function) (value symbol)
  (check-type symbol symbol)
  (setf (fdefinition symbol) value))

(defvar *gensym-counter* 0)
(defun gensym (&optional (thing "G"))
  (check-type thing (or string (integer 0)))
  (if (integerp thing)
      (make-symbol (format nil "G~D" thing))
      (prog1 (make-symbol (format nil "~A~D" thing *gensym-counter*))
        (incf *gensym-counter*))))

;;; TODO: Expand this so it knows about the compiler's constant folders.
(defun constantp (form &optional environment)
  (declare (ignore environment))
  (typecase form
    (symbol (eql (symbol-mode form) :constant))
    (cons (eql (first form) 'quote))
    (t t)))

(defun %progv (symbols values fn)
  ;; Save the special-stack
  (let ((special-stack (%%special-stack-pointer)))
    ;; Bind each variable.
    (do ((s symbols (rest s))
         (v values (rest v)))
        ((null s))
      (check-type (first s) symbol)
      (%%progv-bind (first s) (if v
                                  (first v)
                                  (%unbound-value))))
    (multiple-value-prog1 (funcall fn)
      ;; Now pop the special stack. This is not done with unwind-protect,
      ;; because a non-local exit will unwind the stack anyway.
      (%%unwind-to special-stack))))

(defun function-tag (function)
  (check-type function function)
  (%object-tag function))

(defun function-pool-size (function)
  (check-type function function)
  (let ((address (logand (lisp-object-address function) -16)))
    (memref-unsigned-byte-16 address 2)))

(defun function-code-size (function)
  (check-type function function)
  (let ((address (logand (lisp-object-address function) -16)))
    (* (memref-unsigned-byte-16 address 1) 16)))

(defun function-pool-object (function offset)
  (check-type function function)
  (let ((address (logand (lisp-object-address function) -16))
        (mc-size (truncate (function-code-size function) 8))) ; in words.
    (memref-t address (+ mc-size offset))))

(defun function-code-byte (function offset)
  (check-type function function)
  (let ((address (logand (lisp-object-address function) -16)))
    (memref-unsigned-byte-8 address offset)))

(defun function-gc-info (function)
  "Return the address of and the number of bytes in FUNCTION's GC info."
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (gc-length (memref-unsigned-byte-16 address 3))
         (mc-size (function-code-size function))
         (n-constants (function-pool-size function)))
    (values (+ address mc-size (* n-constants 8)) ; Address.
            gc-length))) ; Length.

(defun decode-function-gc-info (function)
  (multiple-value-bind (address length)
      (function-gc-info function)
    (let ((position 0)
          (result '())
          (register-ids #(:rax :rcx :rdx :rbx :rsp :rbp :rsi :rdi :r8 :r9 :r10 :r11 :r12 :r13 :r14 :r15)))
      (flet ((consume (&optional (errorp t))
               (when (>= position length)
                 (when errorp
                   (error "Reached end of GC Info??"))
                 (return-from decode-function-gc-info (reverse result)))
               (prog1 (memref-unsigned-byte-8 address position)
                 (incf position))))
        (loop (let ((address 0)
                    flags-and-pvr
                    mv-and-ia
                    (pv 0)
                    (n-layout-bits 0)
                    (layout (make-array 32 :element-type 'bit :adjustable t :fill-pointer 0)))
                ;; Read first byte of address, this is where we can terminate.
                (let ((byte (consume nil))
                      (offset 0))
                  (setf address (ldb (byte 7 0) byte)
                        offset 7)
                  (when (logtest byte #x80)
                    ;; Read remaining bytes.
                    (loop (let ((byte (consume)))
                            (setf (ldb (byte 7 offset) address)
                                  (ldb (byte 7 0) byte))
                            (incf offset 7)
                            (unless (logtest byte #x80)
                              (return))))))
                ;; Read flag/pvr byte
                (setf flags-and-pvr (consume))
                ;; Read mv-and-ia
                (setf mv-and-ia (consume))
                ;; Read vs32 pv.
                (let ((shift 0))
                  (loop
                     (let ((b (consume)))
                       (when (not (logtest b #x80))
                         (setf pv (logior pv (ash (logand b #x3F) shift)))
                         (when (logtest b #x40)
                           (setf pv (- pv)))
                         (return))
                       (setf pv (logior pv (ash (logand b #x7F) shift)))
                       (incf shift 7))))
                ;; Read vu32 n-layout bits.
                (let ((shift 0))
                  (loop
                     (let ((b (consume)))
                       (setf n-layout-bits (logior n-layout-bits (ash (logand b #x7F) shift)))
                       (when (not (logtest b #x80))
                         (return))
                       (incf shift 7))))
                ;; Consume layout bits.
                (dotimes (i (ceiling n-layout-bits 8))
                  (let ((byte (consume)))
                    (dotimes (j 8)
                      (vector-push-extend (ldb (byte 1 j) byte) layout))))
                (setf (fill-pointer layout) n-layout-bits)
                (let ((entry '()))
                  (unless (zerop n-layout-bits)
                    (setf (getf entry :layout) layout))
                  (when (logtest flags-and-pvr #b0100)
                    (setf (getf entry :block-or-tagbody-thunk) :rax))
                  (when (logtest flags-and-pvr #b1000)
                    (setf (getf entry :incoming-arguments)
                          (if (eql (ldb (byte 4 4) mv-and-ia) 15)
                              :rcx
                              (ldb (byte 4 4) mv-and-ia))))
                  (unless (eql (ldb (byte 4 0) mv-and-ia) 15)
                    (setf (getf entry :multiple-values)
                          (ldb (byte 4 0) mv-and-ia)))
                  (unless (eql (ldb (byte 4 4) flags-and-pvr) 4)
                    (setf (getf entry :pushed-values-register)
                          (svref register-ids (ldb (byte 4 4) flags-and-pvr))))
                  (unless (zerop pv)
                    (setf (getf entry :pushed-values) pv))
                  (when (logtest flags-and-pvr #b0010)
                    (setf (getf entry :interrupt) t))
                  (push (list* address
                               (if (logtest flags-and-pvr #b0001)
                                   :frame
                                   :no-frame)
                               entry)
                        result))))))))

(defun get-structure-type (name &optional (errorp t))
  (or (get name 'structure-type)
      (and errorp
           (error "Unknown structure type ~S." name))))

(defun concat-symbols (&rest symbols)
  (intern (apply 'concatenate 'string (mapcar 'string symbols))))

(defvar *gentemp-counter* 0)

(defun gentemp (&optional (prefix "T") (package *package*))
  (check-type prefix string)
  (do () (nil)
    (let ((name (format nil "~A~D" prefix (incf *gentemp-counter*))))
      (multiple-value-bind (x status)
          (find-symbol name package)
        (declare (ignore x))
        (unless status (return (intern name package)))))))

(defun special-operator-p (symbol)
  (check-type symbol symbol)
  (member symbol '(block catch eval-when flet function go if labels
                   let let* load-time-value locally macrolet
                   multiple-value-call multiple-value-prog1
                   progn progv quote return-from setq symbol-macrolet
                   tagbody the throw unwind-protect)))

(defun %array-like-p (object)
  (eql (%tag-field object) +tag-object+))

(defun %array-like-header (object)
  (memref-unsigned-byte-64 (ash (%pointer-field object) 4) 0))

(defun %array-like-type (object)
  (logand (1- (ash 1 +array-type-size+))
          (ash (%array-like-header object) (- +array-type-shift+))))

(defmacro define-lap-function (name options &body body)
  `(progn
     (eval-when (:compile-toplevel :load-toplevel :execute)
       (%compiler-defun ',name nil))
     ;; This isn't great, it invokes the assembler at load to build the function.
     ;; But it's OK, compile-file special-cases define-lap-function and produces
     ;; a properly compiled function from it.
     (%defun ',name (assemble-lap ',body ',name
                                  (list :debug-info
                                        ',name
                                        nil ; stack layout
                                        nil ; environment layout
                                        nil ; environment location
                                        ',(when *compile-file-pathname*
                                                (princ-to-string *compile-file-pathname*))
                                        sys.int::*top-level-form-number*
                                        nil ; lambda list (unknown!)
                                        nil))) ; docstring
     ',name))
