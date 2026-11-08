import os, bpy, mathutils
HERE=os.path.dirname(os.path.abspath(__file__)); ROOT=os.path.abspath(os.path.join(HERE,"..",".."))
PH=os.path.join(ROOT,"assets","thirdparty","polyhaven","models")
OUT=os.path.join(ROOT,"build","previews"); os.makedirs(OUT, exist_ok=True)
for asset in ["island_tree_01","island_tree_02","island_tree_03"]:
    path=os.path.join(PH,asset,asset+"_hi.glb")
    if not os.path.exists(path): continue
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    objs=[o for o in bpy.context.scene.objects if o.type=='MESH']
    deps=bpy.context.evaluated_depsgraph_get()
    mins=[1e9]*3; maxs=[-1e9]*3
    for obj in objs:
        ev=obj.evaluated_get(deps)
        for c in ev.bound_box:
            w=ev.matrix_world @ mathutils.Vector(c)
            for i in range(3):
                mins[i]=min(mins[i],w[i]); maxs[i]=max(maxs[i],w[i])
    center=[(mins[i]+maxs[i])*0.5 for i in range(3)]
    size=max(maxs[i]-mins[i] for i in range(3))
    cam_data=bpy.data.cameras.new("c"); cam=bpy.data.objects.new("c",cam_data)
    bpy.context.scene.collection.objects.link(cam)
    cam.location=(center[0]+size*1.0, center[1]-size*1.6, center[2]+size*0.5)
    d=mathutils.Vector(center)-cam.location
    cam.rotation_euler=d.to_track_quat('-Z','Y').to_euler()
    bpy.context.scene.camera=cam
    bpy.context.scene.render.engine='BLENDER_WORKBENCH'
    bpy.context.scene.display.shading.light='STUDIO'
    bpy.context.scene.display.shading.color_type='TEXTURE'
    bpy.context.scene.render.resolution_x=700; bpy.context.scene.render.resolution_y=500
    bpy.context.scene.render.filepath=os.path.join(OUT,asset+"_hi.png")
    bpy.ops.render.render(write_still=True)
    print("[PREV]",asset)
