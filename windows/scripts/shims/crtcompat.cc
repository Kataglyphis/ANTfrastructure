// [LiteRTLM-winfix] CRT compat shim: litert-lm objects reference deprecated CRT globals
// (_timezone/_daylight/_tzname/_environ/_sys_errlist/_sys_nerr + POSIX and __imp_ dllimport forms)
// that the split UCRT does not export as data under litert_lm_main's -nostdlib link. Provide real
// storage initialised from the UCRT accessors + the __imp_ pointer forms the dllimport references
// dereference. Accessors are declared by hand (NOT via <time.h>/<stdlib.h>) because those headers
// declare the very globals we define here as dllimport, which conflicts ("illegal initializer").
typedef unsigned long long crtcompat_size_t;
extern "C" {
int  _get_timezone(long*);
int  _get_daylight(int*);
int  _get_tzname(crtcompat_size_t*, char*, crtcompat_size_t, int);
void _tzset(void);
char*** __p__environ(void);
long   _timezone = 0;
int    _daylight = 0;
char   _crtcompat_tzn0[128] = "";
char   _crtcompat_tzn1[128] = "";
char*  _tzname[2] = { _crtcompat_tzn0, _crtcompat_tzn1 };
int    _sys_nerr = 0;
char*  _sys_errlist[1] = { (char*)"" };
char** _environ = 0;
void* __imp__timezone    = &_timezone;
void* __imp__daylight    = &_daylight;
void* __imp__tzname      = &_tzname;
void* __imp__sys_nerr    = &_sys_nerr;
void* __imp__sys_errlist = &_sys_errlist;
void* __imp__environ     = &_environ;
}
namespace {
struct CrtCompatInit {
    CrtCompatInit() {
        _tzset();
        long tz = 0;  if (_get_timezone(&tz) == 0) _timezone = tz;
        int  dl = 0;  if (_get_daylight(&dl) == 0) _daylight = dl;
        crtcompat_size_t n = 0;
        _get_tzname(&n, _crtcompat_tzn0, sizeof(_crtcompat_tzn0), 0);
        _get_tzname(&n, _crtcompat_tzn1, sizeof(_crtcompat_tzn1), 1);
        _environ = __p__environ() ? *__p__environ() : 0;
    }
};
CrtCompatInit _crt_compat_init;
}
