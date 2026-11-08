import os, bpy
ROOT="/Users/tong/Desktop/极速巅峰"
VEN=os.path.join(ROOT,"assets","venues")
CFG={"grass_medium02":0.32,"grass_bermuda":0.30}
for name,ratio in CFG.items():
    src=os.path.join(VEN,name+".glb")
    dst=os.path.join(VEN,name+"_lod.glb")
    if not os.path.exists(src):
        print("[SKIP]",name); continue
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)
    meshes=[o for o in bpy.context.scene.objects if o.type=='MESH']
    for o in meshes: o.select_set(True)
    bpy.context.view_layer.objects.active=meshes[0]
    if len(meshes)>1: bpy.ops.object.join()
    obj=bpy.context.active_object
    before=len(obj.data.polygons)
    mod=obj.modifiers.new("dec",'DECIMATE'); mod.ratio=ratio
    bpy.ops.object.modifier_apply(modifier="dec")
    bpy.ops.export_scene.gltf(filepath=dst, export_format='GLB', use_selection=True, export_apply=True)
    print("[GRASS LOD] %s %d -> %d" % (name,before,len(obj.data.polygons)))
