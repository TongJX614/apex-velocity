import os, bpy
HERE=os.path.dirname(os.path.abspath(__file__)); ROOT=os.path.abspath(os.path.join(HERE,"..",".."))
PH=os.path.join(ROOT,"assets","thirdparty","polyhaven","models")
CFG={
 "jacaranda_tree":0.09, "pine_sapling_small":0.07, "fir_sapling":0.075,
 "quiver_tree_02":0.16, "shrub_03":0.7, "fern_02":1.0, "dead_tree_trunk_02":0.22,
 "jacaranda_tree":0.085,
 "quiver_tree_01":0.10,
 "quiver_tree_02":0.16,
 "pine_sapling_small":0.06,
 "shrub_02":0.30,
 "shrub_03":0.60,
 "shrub_04":0.35,
 "dead_tree_trunk_02":0.25,
 "fern_02":1.0,
 "tree_small_02":0.006,
}
for asset,ratio in CFG.items():
    src=os.path.join(PH,asset,asset+".gltf")
    if not os.path.exists(src):
        print("[SKIP] missing",asset); continue
    dst=os.path.join(PH,asset,asset+"_lod.glb")
    try:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.gltf(filepath=src)
        meshes=[o for o in bpy.context.scene.objects if o.type=='MESH']
        for o in meshes: o.select_set(True)
        bpy.context.view_layer.objects.active=meshes[0]
        if len(meshes)>1: bpy.ops.object.join()
        obj=bpy.context.active_object
        before=len(obj.data.polygons)
        if ratio < 1.0:
            mod=obj.modifiers.new("dec",'DECIMATE'); mod.ratio=ratio
            bpy.ops.object.modifier_apply(modifier="dec")
        after=len(obj.data.polygons)
        bpy.ops.export_scene.gltf(filepath=dst, export_format='GLB', use_selection=True, export_apply=True)
        print("[LOD] %s %d -> %d" % (asset,before,after))
    except Exception as e:
        print("[FAIL]",asset,e)
