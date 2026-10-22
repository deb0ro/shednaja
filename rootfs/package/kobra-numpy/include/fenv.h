/*
 * Minimal <fenv.h> for uClibc-ng on ARM hard-float (VFP), header-only.
 * uClibc-ng 1.0.31 in the Rockchip toolchain has no fenv for ARM; numpy only
 * needs the exception-flag and rounding-mode calls. Same semantics as musl's
 * arch/arm (fenv-hf): flags and rounding mode live in FPSCR.
 */
#ifndef _KOBRA_FENV_H
#define _KOBRA_FENV_H

#ifdef __cplusplus
extern "C" {
#endif

#define FE_INVALID    1
#define FE_DIVBYZERO  2
#define FE_OVERFLOW   4
#define FE_UNDERFLOW  8
#define FE_INEXACT    16
#define FE_ALL_EXCEPT 31

#define FE_TONEAREST  0
#define FE_UPWARD     0x400000
#define FE_DOWNWARD   0x800000
#define FE_TOWARDZERO 0xc00000
#define __KOBRA_FE_RMODE 0xc00000

typedef unsigned long fexcept_t;
typedef struct { unsigned long __cw; } fenv_t;
#define FE_DFL_ENV ((const fenv_t *) -1)

static inline unsigned long __kobra_get_fpscr(void)
{
	unsigned long r;
	__asm__ __volatile__ ("vmrs %0, fpscr" : "=r"(r));
	return r;
}

static inline void __kobra_set_fpscr(unsigned long r)
{
	__asm__ __volatile__ ("vmsr fpscr, %0" : : "r"(r) : "memory");
}

static inline int feclearexcept(int e)
{
	__kobra_set_fpscr(__kobra_get_fpscr() & ~(unsigned long)(e & FE_ALL_EXCEPT));
	return 0;
}

static inline int feraiseexcept(int e)
{
	__kobra_set_fpscr(__kobra_get_fpscr() | (unsigned long)(e & FE_ALL_EXCEPT));
	return 0;
}

static inline int fetestexcept(int e)
{
	return (int)(__kobra_get_fpscr() & (unsigned long)(e & FE_ALL_EXCEPT));
}

static inline int fegetexceptflag(fexcept_t *f, int e)
{
	*f = __kobra_get_fpscr() & (unsigned long)(e & FE_ALL_EXCEPT);
	return 0;
}

static inline int fesetexceptflag(const fexcept_t *f, int e)
{
	unsigned long m = (unsigned long)(e & FE_ALL_EXCEPT);
	__kobra_set_fpscr((__kobra_get_fpscr() & ~m) | (*f & m));
	return 0;
}

static inline int fegetround(void)
{
	return (int)(__kobra_get_fpscr() & __KOBRA_FE_RMODE);
}

static inline int fesetround(int r)
{
	if ((unsigned)r & ~(unsigned)__KOBRA_FE_RMODE)
		return -1;
	__kobra_set_fpscr((__kobra_get_fpscr() & ~(unsigned long)__KOBRA_FE_RMODE) | (unsigned long)r);
	return 0;
}

static inline int fegetenv(fenv_t *env)
{
	env->__cw = __kobra_get_fpscr();
	return 0;
}

static inline int fesetenv(const fenv_t *env)
{
	unsigned long r = __kobra_get_fpscr() & ~(unsigned long)(FE_ALL_EXCEPT | __KOBRA_FE_RMODE);
	if (env != FE_DFL_ENV)
		r |= env->__cw & (FE_ALL_EXCEPT | __KOBRA_FE_RMODE);
	__kobra_set_fpscr(r);
	return 0;
}

static inline int feholdexcept(fenv_t *env)
{
	fegetenv(env);
	feclearexcept(FE_ALL_EXCEPT);
	return 0;
}

static inline int feupdateenv(const fenv_t *env)
{
	int ex = fetestexcept(FE_ALL_EXCEPT);
	fesetenv(env);
	feraiseexcept(ex);
	return 0;
}

#ifdef __cplusplus
}
#endif

#endif
