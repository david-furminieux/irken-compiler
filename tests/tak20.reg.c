
// This is a hand-rolled version that successfully moves freep & limit
//   into a local variable as well.  However, the macro versions of
//   of allocate & alloc_no_clear seem to have slowed it down.
//
// Numbers:
// global everything: 1000
// local registers:    760
// local freep&limit:  800
//

#include "pxll.h"

static int lookup_field (int tag, int label);

static
inline
pxll_int
get_typecode (object * ob)
{
  if (IMMEDIATE(ob)) {
    if (IS_INTEGER(ob)) {
      return TC_INT;
    } else {
      return (pxll_int)ob & 0xff;
    }
  } else {
    return (pxll_int)*((pxll_int *)ob) & 0xff;
  }
}

// for pvcase/nvcase
static
inline
pxll_int
get_case (object * ob)
{
  if (is_immediate (ob)) {
    if (is_int (ob)) {
      return TC_INT;
    } else {
      return (pxll_int) ob;
    }
  } else {
    return (pxll_int)*((pxll_int *)ob) & 0xff;
  }
}

// for pvcase/nvcase
static
inline
pxll_int
get_case_noint (object * ob)
{
  if (is_immediate (ob)) {
    return (pxll_int) ob;
  } else {
    return (pxll_int) * ((pxll_int*) ob) & 0xff;
  }
}

// for pvcase/nvcase
static
inline
pxll_int
get_case_imm (object * ob)
{
  return (pxll_int)ob;
}

static
inline
pxll_int
get_case_tup (object * ob)
{
  return (pxll_int)*((pxll_int *)ob) & 0xff;
}

static
inline
pxll_int
get_imm_payload (object * ob)
{
  return ((pxll_int) ob) >> 8;
}

static
pxll_int
get_tuple_size (object * ob)
{
  header * h = (header *) ob;
  return (*h)>>8;
}

static
void
indent (int n)
{
  while (n--) {
    fprintf (stdout, "  ");
  }
}

void print_string (object * ob, int quoted);
void print_list (pxll_pair * l);

// this is kinda lame, it's part pretty-printer, part not.
static
object *
dump_object (object * ob, int depth)
{
  // indent (depth);
  if (depth > 100) {
    fprintf (stdout , "...");
    return (object *) PXLL_UNDEFINED;
  }
  if (!ob) {
    fprintf (stdout, "<null>");
  } else if (is_int (ob)) {
    // integer
    fprintf (stdout, "%zd", unbox (ob));
  } else {
    int tc = is_immediate (ob);
    switch (tc) {
    case TC_CHAR:
      if ((pxll_int)ob>>8 == 257) {
	// deliberately out-of-range character
	fprintf (stdout, "#\\eof");
      } else {
	char ch = ((char)((pxll_int)ob>>8));
	switch (ch) {
	case '\000': fprintf (stdout, "#\\nul"); break;
	case ' '   : fprintf (stdout, "#\\space"); break;
	case '\n'  : fprintf (stdout, "#\\newline"); break;
	case '\r'  : fprintf (stdout, "#\\return"); break;
	case '\t'  : fprintf (stdout, "#\\tab"); break;
	default    : fprintf (stdout, "#\\%c", ch);
	}
      }
      break;
    case TC_BOOL:
      fprintf (stdout, ((pxll_int)ob >> 8) & 0xff ? "#t" : "#f");
      break;
    case TC_NIL:
      fprintf (stdout, "()");
      break;
    case TC_UNDEFINED:
      fprintf (stdout, "#u");
      break;
    case TC_EMPTY_VECTOR:
      fprintf (stdout, "#()");
      break;
    case 0: {
      // structure
      header h = (header) (ob[0]);
      int tc = h & 0xff;
      switch (tc) {
      case TC_SAVE: {
	// XXX fix me - now holds saved registers
        pxll_save * s = (pxll_save* ) ob;
        fprintf (stdout, "<save pc=%p\n", s->pc);
        dump_object ((object *) s->lenv, depth+1); fprintf (stdout, "\n");
        dump_object ((object *) s->next, depth+1); fprintf (stdout, ">");
      }
        break;
      case TC_CLOSURE: {
        pxll_closure * c = (pxll_closure *) ob;
        //fprintf (stdout, "<closure pc=%p\n", c->pc);
        //dump_object ((object *) c->lenv, depth+1); fprintf (stdout, ">\n");
	fprintf (stdout, "<closure pc=%p lenv=%p>", c->pc, c->lenv);
      }
        break;
      case TC_TUPLE: {
        pxll_tuple * t = (pxll_tuple *) ob;
        pxll_int n = get_tuple_size (ob);
        int i;
	fprintf (stdout, "<tuple\n");
        for (i=0; i < n-1; i++) {
          dump_object ((object *) t->val[i], depth + 1); fprintf (stdout, "\n");
        }
        dump_object ((object *) t->next, depth + 1);
        fprintf (stdout, ">");
      }
	break;
      case TC_VECTOR: {
        pxll_vector * t = (pxll_vector *) ob;
        pxll_int n = get_tuple_size (ob);
        int i;
	fprintf (stdout, "#(");
        for (i=0; i < n; i++) {
          dump_object ((object *) t->val[i], depth+1);
	  if (i < n-1) {
	    fprintf (stdout, " ");
	  }
        }
        fprintf (stdout, ")");
      }
	break;
      case TC_VEC16: {
        pxll_vec16 * t = (pxll_vec16 *) ob;
        pxll_int n = t->len;
        int i;
	fprintf (stdout, "#16(");
        for (i=0; i < n; i++) {
	  fprintf (stdout, "%d", t->data[i]);
	  if (i < n-1) {
	    fprintf (stdout, " ");
	  }
        }
        fprintf (stdout, ")");
      }
	break;
      case TC_PAIR:
	print_list ((pxll_pair *) ob);
        break;
      case TC_STRING:
	print_string (ob, 1);
	break;
      case TC_BUFFER: {
	pxll_int n = get_tuple_size (ob);
	fprintf (stdout, "<buffer %" PRIuPTR " words %" PRIuPTR " bytes>", n, n * (sizeof(pxll_int)));
	break;
      }
      case TC_SYMBOL:
	print_string (ob[1], 0);
	break;
      default: {
        pxll_vector * t = (pxll_vector *) ob;
        pxll_int n = get_tuple_size (ob);
        int i;
	fprintf (stdout, "{u%d ", (tc - TC_USEROBJ)>>2);
        for (i=0; i < n; i++) {
          dump_object ((object *) t->val[i], depth+1);
	  if (i < n-1) {
	    fprintf (stdout, " ");
	  }
        }
        fprintf (stdout, "}");
      }
      }
    }
      break;
    case TC_USERIMM:
      // a user immediate unit-type...
      fprintf (stdout, "<u%" PRIuPTR ">", (((pxll_int)ob)>>8));
    }
  }
  return (object *) PXLL_UNDEFINED;
}

// for gdb...
void
DO (object * x)
{
  dump_object (x, 0);
  fprintf (stdout, "\n");
  fflush (stdout);
}

// for debugging
void
stack_depth_indent (object * k)
{
  while (k != PXLL_NIL) {
    k = k[1];
    fprintf (stderr, "  ");
  }
}

void
print_string (object * ob, int quoted)
{
  pxll_string * s = (pxll_string *) ob;
  char * ps = s->data;
  int i;
  //fprintf (stderr, "<printing string of len=%d (tuple-len=%d)>\n", s->len, get_tuple_size (ob));
  if (quoted) {
    fputc ('"', stdout);
  }
  for (i=0; i < (s->len); i++, ps++) {
    if (*ps == '"') {
      fputc ('\\', stdout);
      fputc ('"', stdout);
    } else {
      if (isprint(*ps)) {
	fputc (*ps, stdout);
      } else {
	fprintf (stdout, "\\0x%02x", *ps);
      }
    }
    if (i > 50) {
      fprintf (stdout, "...");
      break;
    }
  }
  if (quoted) {
    fputc ('"', stdout);
  }
}

void
print_list (pxll_pair * l)
{
  fprintf (stdout, "(");
  while (1) {
    object * car = l->car;
    object * cdr = l->cdr;
    dump_object (car, 0);
    if (cdr == PXLL_NIL) {
      fprintf (stdout, ")");
      break;
    } else if (!is_immediate (cdr) && GET_TYPECODE (*cdr) == TC_PAIR) {
      fprintf (stdout, " ");
      l = (pxll_pair *) cdr;
    } else {
      fprintf (stdout, " . ");
      dump_object (cdr, 0);
      fprintf (stdout, ")");
      break;
    }
  }
}

int
read_header (FILE * file)
{
  int depth = 0;
  // tiny lisp 'skipper' (as opposed to 'reader')
  do {
    char ch = fgetc (file);
    switch (ch) {
    case '(':
      depth++;
      break;
    case ')':
      depth--;
      break;
    case '"':
      while (fgetc (file) != '"') {
        // empty body
      }
      break;
    default:
      break;
    }
  } while (depth);
  // read terminating newline
  fgetc (file);
  return 0;
}

#ifndef NO_RANGE_CHECK
// used to check array references.  some day we might try to teach
//   the compiler when/how to skip doing this...
static
void
inline
range_check (unsigned int length, unsigned int index)
{
  if (index >= length) {
    fprintf (stderr, "array/string reference out of range: %d[%d]\n", length, index);
    abort();
  }
}
#else
static
void
inline
range_check (unsigned int length, unsigned int index)
{
}
#endif

pxll_int verbose_gc = 1;
pxll_int clear_fromspace = 0;
pxll_int clear_tospace = 0;

pxll_int vm (int argc, char * argv[]);

#include "rdtsc.h"

unsigned long long gc_ticks = 0;

static
void
clear_space (object * p, pxll_int n)
{
  while (n--) {
    *p++ = PXLL_NIL;
  }
}


int
main (int argc, char * argv[])
{
  heap0 = malloc (sizeof (object) * heap_size);
  heap1 = malloc (sizeof (object) * heap_size);
  if (!heap0 || !heap1) {
    fprintf (stderr, "unable to allocate heap\n");
    return -1;
  } else {
    unsigned long long t0, t1;
    pxll_int result;
    if (clear_tospace) {
      clear_space (heap0, heap_size);
    }
    t0 = rdtsc();
    result = vm (argc, argv);
    t1 = rdtsc();
    dump_object ((object *) result, 0);
    fprintf (stdout, "\n");
    fprintf (stderr, "{total ticks: %lld gc ticks: %lld}\n", t1 - t0, gc_ticks);
    return (int) result;
  }
}

// REGISTER_DECLARATIONS //
pxll_int pxll_internal_symbols[] = {(0<<8)|TC_VECTOR, };

// CONSTRUCTED LITERALS //


static object * freep;
static object * limit;

#include "gc.c"

#define PXLL_RETURN(d)	result = r##d; goto *k[3]

#define ALLOCATE(tc,size)			\
  ({						\
  object * save = freep0;			\
  int i;					\
  *freep0 = (object*) (size<<8 | (tc & 0xff));	\
  for (i=size;i;i--) {				\
    *(++freep0) = PXLL_NIL;			\
  }						\
  ++freep0;					\
  save;						\
  })

#define ALLOC_NO_CLEAR(tc, size)		\
  ({						\
  object * save = freep0;			\
  *freep0 = (object*) (size<<8 | (tc & 0xff));	\
  freep0 += size + 1;				\
  save;						\
  })

#define CHECK_HEAP(n,lab)			\
do {						\
  if (freep0 >= limit) {			\
    gc_roots = n;				\
    gc_return = &&lab;				\
    goto gc_flip;				\
  lab:						\
    (void)0;					\
  }						\
 }						\
while (0)


pxll_int
vm (int argc, char * argv[])
{
  int i; // loop counter
  
  register object * r0;
  register object * r1;
  register object * r2;
  register object * r3;
  register object * r4;
  register object * lenv;
  register object * k;
  register object * top;
  register object * freep0;

  void * gc_return;
  int gc_roots;
  object * result;
  object * t;
  int64_t t0;

  limit = heap0 + (heap_size - head_room);
  freep0 = heap0;
  
  goto start;
  
  // GC entry/exit

 gc_flip:

  t0 = rdtsc();
  freep = freep0;
  heap1[0] = lenv;
  heap1[1] = k;
  heap1[2] = top;
  switch (gc_roots) {
  case 5: heap1[7] = r4;
  case 4: heap1[6] = r3;
  case 3: heap1[5] = r2;
  case 2: heap1[4] = r1;
  case 1: heap1[3] = r0;
  }
  do_gc (gc_roots + 3);
  switch (gc_roots) {
  case 5: r4 = heap0[7];
  case 4: r3 = heap0[6];
  case 3: r2 = heap0[5];
  case 2: r1 = heap0[4];
  case 1: r0 = heap0[3];
  }
  lenv = heap0[0];
  k    = heap0[1];
  top  = heap0[2];
  gc_ticks += rdtsc() - t0;
  freep0 = freep;

  goto *gc_return;
  
 start:
  k = ALLOCATE (TC_SAVE, 3);
  k[1] = (object *) PXLL_NIL; // top of stack
  k[2] = (object *) PXLL_NIL; // null environment
  k[3] = &&Lreturn; // continuation that will return from this function.
  // --- BEGIN USER PROGRAM ---
  r0 = ALLOCATE (TC_TUPLE, 3);
  top = r0;
  r0[1] = lenv; lenv = r0;
  // def tak_12
  goto L0;
 FUN_tak_12:
  CHECK_HEAP (0,FUN_tak_12_ch);
  r0 = ((object*) lenv) [2];
  r1 = ((object*) lenv) [3];
  if PXLL_IS_TRUE(PXLL_TEST(unbox(r1)>=unbox(r0))) {
    r0 = ((object*) lenv) [4];
    PXLL_RETURN(0);
  } else {
    r0 = ALLOCATE (TC_TUPLE, 4);
    r1 = (object *) 3;
    r2 = ((object*) lenv) [3];
    r1 = box((pxll_int)unbox(r2)-unbox(r1));
    r0[2] = r1;
    r1 = ((object*) lenv) [4];
    r0[3] = r1;
    r1 = ((object*) lenv) [2];
    r0[4] = r1;
    r1 = top[2];
    t = ALLOCATE (TC_SAVE, 3);
    t[1] = k; t[2] = lenv; t[3] = &&L1; ; k = t;
    r0[1] = r1[2]; lenv = r0; goto FUN_tak_12;
  L1:
    ; lenv = k[2]; k = k[1];
    r0 = result;
    r1 = ALLOCATE (TC_TUPLE, 4);
    r2 = (object *) 3;
    r3 = ((object*) lenv) [4];
    r2 = box((pxll_int)unbox(r3)-unbox(r2));
    r1[2] = r2;
    r2 = ((object*) lenv) [2];
    r1[3] = r2;
    r2 = ((object*) lenv) [3];
    r1[4] = r2;
    r2 = top[2];
    t = ALLOCATE (TC_SAVE, 4);
    t[1] = k; t[2] = lenv; t[3] = &&L2; t[4] = r0; k = t;
    r1[1] = r2[2]; lenv = r1; goto FUN_tak_12;
  L2:
    r0 = k[4]; lenv = k[2]; k = k[1];
    r1 = result;
    r2 = ALLOCATE (TC_TUPLE, 4);
    r3 = (object *) 3;
    r4 = ((object*) lenv) [2];
    r3 = box((pxll_int)unbox(r4)-unbox(r3));
    r2[2] = r3;
    r3 = ((object*) lenv) [3];
    r2[3] = r3;
    r3 = ((object*) lenv) [4];
    r2[4] = r3;
    r3 = top[2];
    t = ALLOCATE (TC_SAVE, 5);
    t[1] = k; t[2] = lenv; t[3] = &&L3; t[4] = r0; t[5] = r1; k = t;
    r2[1] = r3[2]; lenv = r2; goto FUN_tak_12;
  L3:
    r0 = k[4]; r1 = k[5]; lenv = k[2]; k = k[1];
    r2 = result;
    lenv[2] = r2;
    lenv[3] = r0;
    lenv[4] = r1;
    goto FUN_tak_12;
  }
    PXLL_RETURN(0);
  L0:
  r1 = ALLOCATE (TC_CLOSURE, 2);
  r1[1] = &&FUN_tak_12; r1[2] = lenv;
  r0[2] = r1;
  // def loop_21
  goto L4;
  FUN_loop_21:
  CHECK_HEAP(0,FUN_loop_21_ch);
    r0 = ALLOCATE (TC_TUPLE, 2);
    r0[1] = lenv; lenv = r0;
    r1 = ALLOCATE (TC_TUPLE, 4);
    r2 = (object *) 37;
    r1[2] = r2;
    r2 = (object *) 25;
    r1[3] = r2;
    r2 = (object *) 13;
    r1[4] = r2;
    r2 = top[2];
    t = ALLOCATE (TC_SAVE, 4);
    t[1] = k; t[2] = lenv; t[3] = &&L5; t[4] = r0; k = t;
    r1[1] = r2[2]; lenv = r1; goto FUN_tak_12;
    L5:
    r0 = k[4]; lenv = k[2]; k = k[1];
    r1 = result;
    r0[2] = r1;
    r0 = ((object**) lenv) [1][2];
    if PXLL_IS_TRUE(PXLL_TEST(unbox(r0)==0)) {
      r0 = ((object*) lenv) [2];
      PXLL_RETURN(0);
    } else {
      r0 = (object *) 3;
      r1 = ((object**) lenv) [1][2];
      r0 = box((pxll_int)unbox(r1)-unbox(r0));
      lenv = ((object *)lenv)[1];
      lenv[2] = r0;
      goto FUN_loop_21;
    }
    PXLL_RETURN(0);
  L4:
  r1 = ALLOCATE (TC_CLOSURE, 2);
  r1[1] = &&FUN_loop_21; r1[2] = lenv;
  r0[3] = r1;
  r0 = ALLOCATE (TC_TUPLE, 2);
  r1 = (object *) 41;
  r0[2] = r1;
  r1 = top[3];
  r0[1] = r1[2]; lenv = r0; goto FUN_loop_21;
  Lreturn:
  return (pxll_int) result;
}
