;;;; Simplifiy the ast by removing empty nodes and unused variables.

(in-package :sys.c)

(defun simp-form (form)
  (etypecase form
    (cons (case (first form)
	    ((block) (simp-block form))
	    ((go) (simp-go form))
	    ((if) (simp-if form))
	    ((let) (simp-let form))
	    ((load-time-value) (simp-load-time-value form))
	    ((multiple-value-bind) (simp-multiple-value-bind form))
	    ((multiple-value-call) (simp-multiple-value-call form))
	    ((multiple-value-prog1) (simp-multiple-value-prog1 form))
	    ((progn) (simp-progn form))
	    ((progv) (simp-progv form))
	    ((quote) (simp-quote form))
	    ((return-from) (simp-return-from form))
	    ((setq) (simp-setq form))
	    ((tagbody) (simp-tagbody form))
	    ((the) (simp-the form))
	    ((unwind-protect) (simp-unwind-protect form))
	    (t (simp-function-form form))))
    (lexical-variable (simp-variable form))
    (lambda-information (simp-lambda form))))

(defun simp-implicit-progn (x &optional flatten)
  (do ((i x (cdr i)))
      ((endp i))
    ;; Merge nested PROGNs.
    (let ((form (car i)))
      (if (and flatten
	       (consp form)
	       (eq (car form) 'progn)
	       (cdr form))
	  (progn
	    (change-made)
	    (setf (car i) (simp-form (second form))
		  (cdr i) (nconc (cddr form) (cdr i))))
	  (setf (car i) (simp-form form))))))

(defun simp-block (form)
  (cond
     ((eql (lexical-variable-use-count (second form)) 0)
      (change-made)
      (simp-form `(progn ,@(cddr form))))
     ;; (block foo (return-from foo form)) => form
     ((and (eql (lexical-variable-use-count (second form)) 1)
           (eql (length form) 3)
           (eql (first (third form)) 'return-from)
           (eql (second form) (second (third form))))
      (third (third form)))
     (t (simp-implicit-progn (cddr form) t)
	form)))

(defun simp-go (form)
  form)

;;; Hoist LET/M-V-B/PROGN/PROGV forms out of IF tests.
;;;  (if (let bindings form1 ... formn) then else)
;;; =>
;;;  (let bindings form1 ... (if formn then else))
;;; Beware when hoisting LET/M-V-B, must not hoist special bindings.
(defun hoist-form-out-of-if (form)
  (when (and (eql (first form) 'if)
             (listp (second form))
             (member (first (second form)) '(let multiple-value-bind progn progv)))
    (let* ((test-form (second form))
           (len (length test-form)))
      (multiple-value-bind (leading-forms bound-variables)
          (ecase (first test-form)
            ((progn) (values 1 '()))
            ((let) (values 2 (mapcar #'first (second test-form))))
            ((multiple-value-bind) (values 3 (second test-form)))
            ((progv) (values 3 nil)))
        (when (find-if #'symbolp bound-variables)
          (return-from hoist-form-out-of-if nil))
        (append (subseq test-form 0 (max leading-forms (1- len)))
                (if (<= len leading-forms)
                    ;; No body forms, must evaluate to NIL!
                    ;; Fold away the IF.
                    (list (fourth form))
                    (list `(if ,(first (last test-form))
                               ,(third form)
                               ,(fourth form)))))))))

(defun simp-if (form)
  (let ((new-form (hoist-form-out-of-if form)))
    (cond (new-form
           (change-made)
           (simp-form new-form))
          ((and (listp (second form))
                (eql (first (second form)) 'if))
           ;; Rewrite (if (if ...) ...).
           (let* ((test-form (second form))
                  (new-block (make-block-information :name (gensym "if-escape")
                                                     :definition-point *current-lambda*
                                                     :ignore nil
                                                     :dynamic-extent nil))
                  (new-tagbody (make-tagbody-information :definition-point *current-lambda*
                                                         :go-tags '()))
                  (then-tag (make-go-tag :name (gensym "if-then")
                                         :tagbody new-tagbody))
                  (else-tag (make-go-tag :name (gensym "if-else")
                                         :tagbody new-tagbody)))
             (push then-tag (tagbody-information-go-tags new-tagbody))
             (push else-tag (tagbody-information-go-tags new-tagbody))
             `(block ,new-block
                (tagbody ,new-tagbody
                   ,(simp-form `(if ,(second test-form)
                                    ;; Special case here to catch (if a a b), generated by OR.
                                    ,(if (eql (second test-form) (third test-form))
                                       `(go ,then-tag ,(go-tag-tagbody then-tag))
                                       `(if ,(third test-form)
                                            (go ,then-tag ,(go-tag-tagbody then-tag))
                                            (go ,else-tag ,(go-tag-tagbody else-tag))))
                                    (if ,(fourth test-form)
                                        (go ,then-tag ,(go-tag-tagbody then-tag))
                                        (go ,else-tag ,(go-tag-tagbody else-tag)))))
                   ,then-tag
                   (return-from ,new-block ,(simp-form (third form)) ,new-block)
                   ,else-tag
                   (return-from ,new-block ,(simp-form (fourth form)) ,new-block)))))
          (t
           (setf (second form) (simp-form (second form))
                 (third form) (simp-form (third form))
                 (fourth form) (simp-form (fourth form)))
           form))))

(defun simp-let (form)
  ;; Merge nested LETs when possible, do not merge special bindings!
  (do ((nested-form (caddr form) (caddr form)))
      ((or (not (consp nested-form))
	   (not (eq (first nested-form) 'let))
           (some 'symbolp (mapcar 'first (second form)))
	   (and (second nested-form)
                (symbolp (first (first (second nested-form)))))))
    (change-made)
    (if (null (second nested-form))
	(setf (cddr form) (nconc (cddr nested-form) (cdddr form)))
	(setf (second form) (nconc (second form) (list (first (second nested-form))))
	      (second nested-form) (rest (second nested-form)))))
  ;; Remove unused values with no side-effects.
  (setf (second form) (remove-if (lambda (b)
				   (let ((var (first b))
					 (val (second b)))
				     (and (lexical-variable-p var)
					  (or (lambda-information-p val)
					      (and (consp val) (eq (first val) 'quote))
					      (and (lexical-variable-p val)
						   (localp val)
						   (eql (lexical-variable-write-count val) 0)))
					  (eql (lexical-variable-use-count var) 0)
					  (progn (change-made)
						 (flush-form val)
						 t))))
				 (second form)))
  (dolist (b (second form))
    (setf (second b) (simp-form (second b))))
  ;; Remove the LET if there are no values.
  (if (second form)
      (progn
	(simp-implicit-progn (cddr form) t)
	form)
      (progn
	(change-made)
	(simp-form `(progn ,@(cddr form))))))

;;;(defun simp-load-time-value (form))

(defun simp-multiple-value-bind (form)
  ;; If no variables are used, or there are no variables then
  ;; remove the form.
  (cond ((every (lambda (var)
                  (and (lexical-variable-p var)
                       (zerop (lexical-variable-use-count var))))
                (second form))
         (change-made)
         (simp-form `(progn ,@(cddr form))))
        (t (simp-implicit-progn (cddr form) t)
           form)))

(defun simp-multiple-value-call (form)
  (simp-implicit-progn (cdr form))
  form)

(defun simp-multiple-value-prog1 (form)
  (setf (second form) (simp-form (second form)))
  (simp-implicit-progn (cddr form) t)
  form)

(defun simp-progn (form)
  (cond ((null (cdr form))
	 ;; Flush empty PROGNs.
	 (change-made)
	 ''nil)
	((null (cddr form))
	 ;; Reduce single form PROGNs.
	 (change-made)
	 (simp-form (second form)))
	(t (simp-implicit-progn (cdr form) t)
	   form)))

(defun simp-progv (form)
  (setf (second form) (simp-form (second form))
	(third form) (simp-form (third form)))
  (simp-implicit-progn (cdddr form) t)
  form)

(defun simp-quote (form)
  form)

(defun simp-return-from (form)
  (setf (third form) (simp-form (third form)))
  (setf (fourth form) (simp-form (fourth form)))
  form)

(defun simp-setq (form)
  (setf (third form) (simp-form (third form)))
  form)

(defun simp-tagbody (form)
  (labels ((flatten (x)
	     (cond ((and (consp x)
			 (eq (car x) 'progn))
		    (change-made)
		    (apply #'nconc (mapcar #'flatten (cdr x))))
		   ((and (consp x)
			 (eq (car x) 'tagbody))
		    ;; Merge directly nested TAGBODY forms, dropping unused go tags.
		    (change-made)
		    (setf (tagbody-information-go-tags (second form))
			  (nconc (tagbody-information-go-tags (second form))
				 (delete-if (lambda (x) (eql (go-tag-use-count x) 0))
					    (tagbody-information-go-tags (second x)))))
		    (apply #'nconc (mapcar (lambda (x)
					     (if (go-tag-p x)
						 (unless (eql (go-tag-use-count x) 0)
						   (setf (go-tag-tagbody x) (second form))
						   (list x))
						 (flatten x)))
					   (cddr x))))
		   (t (cons (simp-form x) nil)))))
    (setf (tagbody-information-go-tags (second form))
	  (delete-if (lambda (x) (eql (go-tag-use-count x) 0))
		     (tagbody-information-go-tags (second form))))
    (do* ((i (cddr form) (cdr i))
	  (result (cdr form))
	  (tail result))
	 ((endp i))
      (let ((x (car i)))
	(if (go-tag-p x)
	    ;; Drop unused go tags.
	    (if (eql (go-tag-use-count x) 0)
		(change-made)
		(setf (cdr tail) (cons x nil)
		      tail (cdr tail)))
	    (setf (cdr tail) (flatten x)
		  tail (last tail)))))
    ;; Reduce tagbodys with no tags to progn.
    (cond ((tagbody-information-go-tags (second form))
	   form)
	  ((null (cddr form))
	   (change-made)
	   ''nil)
	  ((null (cdddr form))
	   (change-made)
	   (caddr form))
	  (t (change-made)
	     `(progn ,@(cddr form))))))

(defun simp-the (form)
  (cond ((eql (second form) 't)
         (change-made)
         (simp-form (third form)))
        (t (setf (third form) (simp-form (third form)))
           form)))

(defun simp-unwind-protect (form)
  (setf (second form) (simp-form (second form)))
  (simp-implicit-progn (cddr form) t)
  form)

(defun simp-function-form (form)
  ;; (funcall 'symbol ...) -> (symbol ...)
  (cond ((and (eql (first form) 'funcall)
              (listp (second form))
              (= (list-length (second form)) 2)
              (eql (first (second form)) 'quote)
              (symbolp (second (second form))))
         (change-made)
         (simp-implicit-progn (cddr form))
         (list* (second (second form)) (cddr form)))
        (t (simp-implicit-progn (cdr form))
           form)))

(defun simp-variable (form)
  form)

(defun simp-lambda (form)
  (let ((*current-lambda* form))
    (dolist (arg (lambda-information-optional-args form))
      (setf (second arg) (simp-form (second arg))))
    (dolist (arg (lambda-information-key-args form))
      (setf (second arg) (simp-form (second arg))))
    (simp-implicit-progn (lambda-information-body form) t))
  form)
