/* 
 * Copyright (c) 2005 - 2007 Miek Gieben
 * See LICENSE for the license
 */

#include "rdup.h"

/* options */
gboolean opt_null 	   = FALSE;                   /* delimit all in/output with \0  */
gboolean opt_onefilesystem = FALSE;   		      /* stay on one filesystem */
gboolean opt_nobackup      = TRUE;             	      /* don't ignore .nobackup files */
gboolean opt_removed       = TRUE; 		      /* whether to print removed files */
gboolean opt_modified      = TRUE; 		      /* whether to print modified files */
gboolean opt_attr	   = FALSE; 	              /* whether to use xattr */
gboolean opt_local  	   = FALSE; 		      /* check for file size changes */
char *opt_format 	   = "%p%T %b %u %g %l %s %n\n"; /* format of rdup output */
char qstr[BUFSIZE + 1];				      /* static string for quoting */
gint opt_verbose 	   = 0;                       /* be more verbose */
size_t opt_size            = 0;                       /* only output files smaller then <size> */
time_t opt_timestamp       = 0;                       /* timestamp file */
sig_atomic_t sig           = 0;

/* crawler.c */
void dir_crawl(GTree *t, char *path, gboolean new_dir);
gboolean dir_prepend(GTree *t, char *path);
/* signal.c */
void got_sig(int signal);
/* usage.c */
void usage(FILE *f);
/* regexp.c */
int regexp_init(char *f);

static void
msg_va_list(const char *fmt, va_list args)
{
        fprintf(stderr, "** %s: ", PROGNAME);
        vfprintf(stderr, fmt, args);
        fprintf(stderr, "\n");
}

void
msg(const char *fmt, ...)
{
        va_list args;
        va_start(args, fmt);
        msg_va_list(fmt, args);
        va_end(args);
}

/**
 * subtrace tree *b from tree *a, leaving
 * the elements that are only in *a. Essentially
 * a double diff: A diff (A diff B)
 */
static GTree *
g_tree_substract(GTree *a, GTree *b)
{
	GTree 	         *diff;
	struct substract s;

	diff = g_tree_new(gfunc_equal);
	s.d = diff;
	s.b = b;
	/* everything in a, but NOT in b 
	 * diff gets filled inside this function */
	g_tree_foreach(a, gfunc_substract, (gpointer)&s);
	return diff;
}

/**
 * read a filelist, which should hold our previous
 * backup list
 */
static GTree *
g_tree_read_file(FILE *fp)
{
	char 	      *buf;
	char          *n;
	char          *p;
	char 	      *q;
	char 	      delim;
	mode_t        modus;
	GTree         *tree;
	struct entry *e;
	size_t        s;
	size_t 	      l;
	size_t        f_name_size;
	size_t        str_len;
	dev_t	      f_dev;
	ino_t	      f_ino;

	tree = g_tree_new(gfunc_equal);
	buf  = g_malloc(BUFSIZE + 1);
	s    = BUFSIZE;
	l    = 1;

	if (opt_null)
		delim = '\0';
	else
		delim = '\n';

	while ((rdup_getdelim(&buf, &s, delim, fp)) != -1) {
		if (sig != 0) {
			fclose(fp);
			signal_abort(sig);
		}

		if (s < LIST_MINSIZE) {
			msg("Corrupt entry in filelist at line: %zd", l);
			l++;
			continue;
		}
		if (!opt_null) {
			n = strrchr(buf, '\n');
			if (n)
				*n = '\0';
		}

		/* get modus */
		buf[LIST_SPACEPOS] = '\0';
		modus = (mode_t)atoi(buf);
		if (modus == 0) {
			msg("Corrupt entry in filelist at line: %zd, `%s\' should be numerical", l, buf);
			l++; 
			continue;
		}

		/* the dev */
		q = buf + LIST_SPACEPOS + 1;
		p = strchr(buf + LIST_SPACEPOS + 1, ' ');
		if (!p) {
			msg("Corrupt entry in filelist at line: %zd, no space found", l);
			l++; 
			continue;
		}
		*p = '\0';
		f_dev = (dev_t)atoi(q);
		if (f_dev == 0) {
			msg("Corrupt entry in filelist at line: %zd, zero device", l);
			l++; 
			continue;
		}

		/* the inode */
		q = p + 1;
		p = strchr(p + 1, ' ');
		if (!p) {
			msg("Corrupt entry in filelist at line: %zd, no space found", l);
			l++; 
			continue;
		}
		*p = '\0';
		f_ino = (ino_t)atoi(q);
		if (f_ino == 0) {
			msg("Corrupt entry in filelist at line: %zd, zero inode", l);
			l++; 
			continue;
		}
		/* the path size */
		q = p + 1;
		p = strchr(p + 1, ' ');
		if (!p) {
			msg("Corrupt entry in filelist at line: %zd, no space found", l);
			l++; 
			continue;
		}
		/* the file's name */
		*p = '\0';
		f_name_size = (size_t)atoi(q);
		str_len = strlen(p + 1);
		if (str_len != f_name_size) {
			msg("Corrupt entry in filelist at line: %zd, length `%zd\' does not match `%zd\'", l,
					str_len, f_name_size);
			l++; 
			continue;
		}

		e = g_malloc(sizeof(struct entry));
		e->f_name      = g_strdup(p + 1);
		e->f_name_size = f_name_size;
		e->f_mode      = modus;
		e->f_uid       = 0;
		e->f_gid       = 0;
		e->f_size      = 0;
		e->f_ctime     = 0;
		e->f_dev       = f_dev;
		e->f_ino       = f_ino;
		g_tree_insert(tree, (gpointer)e, VALUE);
		l++;
	}
	g_free(buf);
	return tree;
}

/**
 * return the m_time of the filelist
 */
static time_t
timestamp(char *f)
{
	struct stat s;
	if (lstat(f, &s) != 0) {
		return 0;
	}
	return s.st_ctime;
}

int
main(int argc, char **argv)
{
	GTree 	*backup; 	/* on disk stuff */
	GTree 	*remove;	/* what needs to be rm'd */
	GTree 	*curtree; 	/* previous backup tree */
	GTree	*new;		/* all that is new */
	GTree	*changed;	/* all that is possibly changed */
	FILE 	*fplist;
	gint    i;
	int 	c;
	char 	*crawl;
	char    pwd[BUFSIZE + 1];
	char    *time;
	gboolean devnull = FALSE;	/* hack: remember if we open /dev/null */

	struct sigaction sa;

	/* setup our signal handling */
	sa.sa_flags   = 0;
	sigfillset(&sa.sa_mask);

	sa.sa_handler = got_sig;
	sigaction(SIGPIPE, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	curtree = g_tree_new(gfunc_equal);
	backup  = g_tree_new(gfunc_equal);
	remove  = NULL;
	opterr = 0;
	time = NULL;

	if (((getuid() != geteuid()) || (getgid() != getegid()))) {
		msg("Will not run suid/sgid for safety reasons", PROGNAME);
		exit(EXIT_FAILURE);
        }

	if (!getcwd(pwd, BUFSIZE)) {
		msg("Could not get current working directory");
		exit(EXIT_FAILURE);
	}
	for(c = 0; c < argc; c++) {
		if (strlen(argv[c]) > BUFSIZE) {
			msg("Argument length overrun");
			exit(EXIT_FAILURE);
		}
	}

	while ((c = getopt (argc, argv, "acrlmhVnN:s:vqx0F:E:")) != -1) {
		switch (c) {
			case 'F':
				opt_format = optarg;
				break;
			case 'E':
				if (!regexp_init(optarg)) 
					exit(EXIT_FAILURE);
				break;
			case 'a':
#ifdef HAVE_ATTR_XATTR_H
				opt_attr = TRUE;
#endif /* HAVE_ATTR_XATTR_H */
#ifdef HAVE_OPENAT
				opt_attr = TRUE;
#endif /* HAVE_OPENAT */
				break;
			case 'c':
				opt_format = "%p%T %b %u %g %l %s\n%n%C";
				break;
			case 'h':
				usage(stdout);
				exit(EXIT_SUCCESS);
			case 'V':
				fprintf(stdout, "%s %s\n", PROGNAME, VERSION);
				exit(EXIT_SUCCESS);
			case 'n':
				opt_nobackup = FALSE;
				break;
			case 'N': 
				opt_timestamp = timestamp(optarg);
				time = optarg;
				break;
			case 'v':
				opt_verbose++; 
				if (opt_verbose > 2) {
					opt_verbose = 2;
				}
				break;
			case 'l':
				opt_local = TRUE;
				break;
			case 'r':
				opt_removed = TRUE;
				opt_modified = FALSE;
				break;
			case 'm':
				opt_removed = FALSE;
				opt_modified = TRUE;
				break;
			case 'x':
				opt_onefilesystem = TRUE;
				break;
			case '0':
				opt_null = TRUE;
				break;
			case 's':
				opt_size = atoi(optarg);
				if (opt_size == 0) {
					msg("-s requires a numerical value");
					exit(EXIT_FAILURE);
				}
				break;
			default:
				msg("Unknown option seen");
				exit(EXIT_FAILURE);
		}
	}
	argc -= optind;
	argv += optind;

	if (argc < 2) {
		usage(stdout);
		exit(EXIT_FAILURE);
	}

	if (strcmp(argv[0], "/dev/null") == 0)
		devnull = TRUE;

	if (!(fplist = fopen(argv[0], "a+"))) {
		msg("Could not open filelist `%s\': %s", argv[0], strerror(errno));
		exit(EXIT_FAILURE);
	} else {
		rewind(fplist);
	}

	curtree = g_tree_read_file(fplist);
	
	for (i = 1; i < argc; i++) {
		if (argv[i][0] != DIR_SEP) {
			crawl = g_strdup_printf("%s%c%s", pwd, DIR_SEP, argv[i]);
		} else {
			crawl = g_strdup(argv[i]);
		}

		/* add dirs leading up the dir/file */
		if (!dir_prepend(backup, crawl)) {
			msg("Skipping `%s\'", crawl);
			continue;
		}
		/* descend into the dark, misty directory */
		dir_crawl(backup, crawl, FALSE);
		g_free(crawl);
	}
#ifdef _DEBUG_RACE
	fprintf(stderr, "** Sleeping\n");
	sleep(3);
#endif /* _DEBUG_RACE */

	/* everything that is gone from the filesystem */
	remove  = g_tree_substract(curtree, backup);

	/* everything that is really new on the filesystem */
	new     = g_tree_substract(backup, curtree);

	/* all stuff that should be ctime checked, to see if it has 
	 * changed */
	changed = g_tree_substract(backup, new);
	/* some dirs might still linger in changed, while they are in fact
	 * removed, kill those here */
	changed = g_tree_substract(changed, remove);

	/* first what to remove, then what to backup */
	g_tree_foreach(remove, gfunc_remove, NULL);
	g_tree_foreach(changed, gfunc_backup, NULL);
	g_tree_foreach(new, gfunc_new, NULL);

	/* write new filelist */
	if (!devnull && ftruncate(fileno(fplist), 0) != 0) {
		msg("Could not truncate filelist file `%s\': %s", argv[0],
			strerror(errno));
	}
	/* write temporary file and the move it */
	g_tree_foreach(backup, gfunc_write, fplist);
	fclose(fplist);
	/* re-touch the timestamp file */
	if (time && (creat(time, S_IRUSR | S_IWUSR) == -1)) {
		msg("Could not create timestamp file `%s\': %s", time, strerror(errno));
		exit(EXIT_FAILURE);
	}

	g_tree_foreach(curtree, gfunc_free, NULL);
	g_tree_foreach(backup, gfunc_free, NULL);
	g_tree_destroy(curtree);
	g_tree_destroy(backup);
	g_tree_destroy(remove);
	exit(EXIT_SUCCESS);
}
