
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
      case TC_ENV: {
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
pxll_int clear_tospace = 1;

pxll_int vm (int argc, char * argv[]);

#include "rdtsc.h"

uint64_t gc_ticks = 0;

#if 0
static
void
clear_space (object * p, pxll_int n)
{
  while (n--) {
    *p++ = PXLL_NIL;
  }
}
#else
void
clear_space (object * p, pxll_int n)
{
  memset (p, 0, sizeof(object) * n);
}
#endif


static object *
varref (object * lenv, pxll_int depth, pxll_int index) {
  while (depth--) {
    lenv = lenv[1];
  }
  return lenv[index+2];
}

static void
varset (object * lenv, pxll_int depth, pxll_int index, object * val) {
  while (depth--) {
    lenv = lenv[1];
  }
  lenv[index+2] = val;
}

static object * lenv = PXLL_NIL;
static object * k = PXLL_NIL;
static object * top = PXLL_NIL; // top-level (i.e. 'global') environment
static object * t = 0; // temp - for swaps & building tuples
static object * result;
static object * limit; // = heap0 + (heap_size - head_room);
static object * freep; // = heap0;

// REGISTER_DECLARATIONS //

// CONSTRUCTED LITERALS //

#include "gc1.c"

static object *
allocate (pxll_int tc, pxll_int size)
{
  object * save = freep;
  *freep = (object*) (size<<8 | (tc & 0xff));
#if 0
  // at least on the g5, this technique is considerably faster than using memset
  //   in gc_flip() to 'pre-clear' the heap... probably a cache effect...
  while (size--) {
    // this keeps gc from being confused by partially-filled objects.
    *(++freep) = PXLL_NIL;
  }
  ++freep;
#else
  // if you use this version, be sure to set <clear_tospace>!
  freep += size + 1;
#endif
  return save;  
}

  // this is emitted by the backend for %make-tuple
static object *
alloc_no_clear (pxll_int tc, pxll_int size)
{
  object * save = freep;
  *freep = (object*) (size<<8 | (tc & 0xff));
  freep += size + 1;
  return save;  
}

static uint64_t program_start_time;
static uint64_t program_end_time;

typedef void(*kfun)(void);
static void exit_continuation (void)
{
  program_end_time = rdtsc();
  dump_object ((object *) result, 0);
  fprintf (stdout, "\n");
  fprintf (stderr, "{total ticks: %" PRIu64 " gc ticks: %" PRIu64 "}\n", program_end_time - program_start_time, gc_ticks);
  exit((int)(intptr_t)result);
}

static void toplevel (void);

// XXX rename these!
static int argc;
static char ** argv;


int
main (int _argc, char * _argv[])
{
  heap0 = malloc (sizeof (object) * heap_size);
  heap1 = malloc (sizeof (object) * heap_size);
  if (!heap0 || !heap1) {
    fprintf (stderr, "unable to allocate heap\n");
    return -1;
  } else {
    if (clear_tospace) {
      clear_space (heap0, heap_size);
    }
    argc = _argc;
    argv = _argv;
    limit = heap0 + (heap_size - head_room);
    freep = heap0;  
    k = allocate (TC_SAVE, 3);
    k[1] = (object *) PXLL_NIL; // top of stack
    k[2] = (object *) PXLL_NIL; // null environment
    k[3] = exit_continuation;
    program_start_time = rdtsc();
    toplevel();
    return 1;
  }
}


#define PXLL_RETURN(d) result = r##d; ((kfun)(k[3]))();
#define O object *
