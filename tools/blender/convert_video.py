import bpy, sys, os

argv = sys.argv[sys.argv.index("--") + 1:]
src = argv[0]
dst = argv[1]
seconds = float(argv[2])
width = int(argv[3])

scene = bpy.context.scene
if scene.sequence_editor is None:
    scene.sequence_editor_create()
se = scene.sequence_editor
strips = getattr(se, "strips", None)
if strips is None:
    strips = getattr(se, "sequences")
movie = strips.new_movie(name="clip", filepath=src, channel=1, frame_start=1)
try:
    strips.new_sound(name="snd", filepath=src, channel=2, frame_start=1)
except Exception as exc:
    print("[CONVERT] audio strip skipped:", exc)

fps = max(1, int(round(scene.render.fps)))
scene.frame_start = 1
scene.frame_end = max(1, min(movie.frame_final_duration, int(round(seconds * fps))))
scene.render.resolution_x = width
scene.render.resolution_y = int(round(width * 9.0 / 16.0))
scene.render.resolution_percentage = 100
scene.render.fps = fps
scene.render.use_sequencer = True
scene.render.image_settings.media_type = 'VIDEO'
scene.render.image_settings.file_format = 'FFMPEG'
ff = scene.render.ffmpeg
ff.format = 'OGG'
ff.codec = 'THEORA'
ff.audio_codec = 'VORBIS'
ff.constant_rate_factor = 'MEDIUM'
ff.ffmpeg_preset = 'GOOD'
ff.audio_bitrate = 128
os.makedirs(os.path.dirname(dst), exist_ok=True)
scene.render.filepath = dst
print("[CONVERT] %s -> %s (%d frames, %dx%d)" % (src, dst, scene.frame_end, scene.render.resolution_x, scene.render.resolution_y))
bpy.ops.render.render(animation=True)
print("[CONVERT] done:", dst)
