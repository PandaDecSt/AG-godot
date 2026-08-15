extends SceneTree
func _initialize() -> void:
    var s = RDShaderSource.new()
    print("CLASS: ", s.get_class())
    var pl := s.get_property_list()
    for p in pl:
        var n = p.get("name","")
        if "source" in String(n).to_lower() or "language" in String(n).to_lower() or "stage" in String(n).to_lower() or "entry" in String(n).to_lower():
            print("PROP: ", n)
    # 试探候选：source_code (String) / language (enum)
    s.source_code = "// test"
    print("STRING_OK source_code=", s.source_code)
    print("LANG_CONST GLSL: ", RenderingDevice.SHADER_LANGUAGE_GLSL)
    s.language = RenderingDevice.SHADER_LANGUAGE_GLSL
    print("LANG_OK")
    quit()
