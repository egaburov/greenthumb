	mul.wide.u32 	%r2, %r1, %r0, -1431655765;
	shr.u32 	%r1, %r1, 1;
	mul.lo.s32 	%r1, %r1, 3;
	sub.s32 	%r1, %r0, %r1;
	and.b32  	%r2, %r1, 1;
	setp.eq.b32	%p0, %r2, 0;
	selp.b32	%r10, %r4, %r6, %p0;
	selp.b32	%r11, %r5, %r7, %p0;
	selp.b32	%r12, %r6, %r8, %p0;
	selp.b32	%r13, %r7, %r9, %p0;
	selp.b32	%r14, %r8, %r4, %p0;
	selp.b32	%r15, %r9, %r5, %p0;
	and.b32  	%r2, %r1, 2;
	setp.eq.s32	%p0, %r2, 0;
	selp.b32	%r4, %r10, %r14, %p0;
	selp.b32	%r5, %r11, %r15, %p0;
	selp.b32	%r6, %r12, %r10, %p0;
	selp.b32	%r7, %r13, %r11, %p0;
	selp.b32	%r8, %r14, %r12, %p0;
	selp.b32	%r9, %r15, %r13, %p0;
