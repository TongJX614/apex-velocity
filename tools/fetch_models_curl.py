import json, os, subprocess, sys
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
ROOT=os.path.abspath(os.path.join(os.path.dirname(__file__),".."))
PH=os.path.join(ROOT,"assets","thirdparty","polyhaven","models")
def api(url):
    out=subprocess.check_output(["curl","-s","--max-time","40","-H","User-Agent: "+UA,url])
    return json.loads(out)
def dl(url,dest):
    os.makedirs(os.path.dirname(dest),exist_ok=True)
    if os.path.exists(dest) and os.path.getsize(dest)>1024: return
    subprocess.run(["curl","-fL","--retry","3","--max-time","240","-C","-","-A",UA,"-o",dest,url],check=False)
    if not os.path.exists(dest) or os.path.getsize(dest)<1024:
        print("  FAIL", os.path.basename(dest)); return False
    print("  ok", os.path.relpath(dest,ROOT), "%.1f MB" % (os.path.getsize(dest)/1048576))
    return True
assets=sys.argv[1:]
for asset in assets:
    print("[model]",asset)
    files=api(f"https://api.polyhaven.com/files/{asset}")
    node=files.get("gltf",{}).get("1k",{}).get("gltf")
    if not node:
        print("  no gltf"); continue
    base=os.path.join(PH,asset)
    dl(node["url"], os.path.join(base,asset+".gltf"))
    for rel,entry in node.get("include",{}).items():
        if entry.get("url"):
            dl(entry["url"], os.path.join(base,rel))
