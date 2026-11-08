import os, bpy
HERE=os.path.dirname(os.path.abspath(__file__)); ROOT=os.path.abspath(os.path.join(HERE,"..",".."))
PH=os.path.join(ROOT,"assets","thirdparty","polyhaven","models")
PREV=os.path.join(ROOT,"build","previews"); os.makedirs(PREV, exist_ok=True)
CFG={"island_tree_01":0.075,"island_tree_02":0.15,"island_tree_03":0.045}
for asset,ratio in CFG.items():
    src=os.path.join(PH,asset,asset+".gltf"); dst=os.path.join(PH,asset,asset+"_hi.glb")
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
    after=len(obj.data.polygons)
    bpy.ops.export_scene.gltf(filepath=dst, export_format='GLB', use_selection=True, export_apply=True)
    print("[REDEC] %s %d -> %d (%s)" % (asset,before,after,dst))
