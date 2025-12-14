package main

import rl  "vendor:raylib"
import fmt "core:fmt"

PERF_TEST_ENABLED :: true

Perf_T0: f64

Perf_Frames: u64
Perf_Sum_Frame_Sec: f64
Perf_Sum_Update_Sec: f64
Perf_Sum_Draw_Sec: f64
Perf_Max_Frame_Sec: f64

Perf_Clear_Calls: u64
Perf_Cell_Calls:  u64
Perf_Glyph_Calls: u64

update_perf_test :: proc(frame_dt, update_dt, draw_dt: f64) {
	when !PERF_TEST_ENABLED {
		return
	}

	now := rl.GetTime()

	if Perf_T0 == 0 {
		Perf_T0 = now
	}

	Perf_Frames += 1
	Perf_Sum_Frame_Sec += frame_dt
	Perf_Sum_Update_Sec += update_dt
	Perf_Sum_Draw_Sec += draw_dt
	if frame_dt > Perf_Max_Frame_Sec { Perf_Max_Frame_Sec = frame_dt }

	interval := now - Perf_T0
	if interval < 1.0 {
		return
	}

	frames_f := cast(f64)(Perf_Frames)
	fps := frames_f / interval

	avg_frame_ms  := (Perf_Sum_Frame_Sec  / frames_f) * 1000.0
	avg_update_ms := (Perf_Sum_Update_Sec / frames_f) * 1000.0
	avg_draw_ms   := (Perf_Sum_Draw_Sec   / frames_f) * 1000.0
	worst_ms      := Perf_Max_Frame_Sec * 1000.0

	gpf := cast(f64)(Perf_Glyph_Calls) / frames_f
	cpf := cast(f64)(Perf_Cell_Calls)  / frames_f

	cols: i32 = 0
	rows: i32 = 0
	if Cell_W > 0 && Cell_H > 0 {
		cols = cast(i32)(rl.GetRenderWidth()) / Cell_W
		rows = cast(i32)(rl.GetRenderHeight()) / Cell_H
	}

	fmt.printf(
		"PERF %.1f fps | frame %.2fms (u %.2fms, d %.2fms) worst %.2fms | glyph %.1f/f cell %.1f/f | grid %dx%d\n",
		fps, avg_frame_ms, avg_update_ms, avg_draw_ms, worst_ms, gpf, cpf, cols, rows,
	)

	Perf_T0 = now
	Perf_Frames = 0
	Perf_Sum_Frame_Sec = 0
	Perf_Sum_Update_Sec = 0
	Perf_Sum_Draw_Sec = 0
	Perf_Max_Frame_Sec = 0

	Perf_Clear_Calls = 0
	Perf_Cell_Calls = 0
	Perf_Glyph_Calls = 0
}

