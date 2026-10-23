# The game's materials on the arm and the sword in animation_sources/fp_arms/fp_arms.blend, so the
# scene can be looked at textured (the 3D view's Material Preview). build_scene.py runs it; run it
# on its own on the open scene to refresh the materials without rebuilding anything.
#
# Each entry copies a Godot material (assets/.../materials/*.tres): its albedo, normal map and the
# packed map (green = roughness, blue = metallic), each map multiplied by the material's own value
# as Godot does -- the rogue's materials have metallic 0 (so even rogue_metal is not metal in the
# game), the sword's 1. The images are the project's own files, referenced, not copied. AO (the
# ORM's red) is left out: Blender's Principled BSDF has no input for it.
import bpy, os

try:
    HERE = os.path.dirname(os.path.abspath(__file__))
except NameError:
    HERE = r"D:\Downloads\Godot_v4.7.2-stable_win64.exe\herald-of-oblivion\tools\blender\fp_arms"
PROJECT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
ROGUE = os.path.join("assets", "models", "characters", "rogue", "textures", "rogue_%s_%s.png")
SWORD = os.path.join("assets", "models", "weapons", "sword", "textures", "sword_%s.png")
SHIELD = os.path.join("assets", "models", "weapons", "shield", "textures", "shield_%s.png")
BODY_SPECULAR = 0.2  # PlayerBody.body_specular (metallic_specular on the rogue's materials)

# Blender material name -> (albedo, normal, packed map, metallic, roughness, specular)
MATERIALS = {
    "rogue_leathera": (ROGUE % ("leathera", "albedo"), ROGUE % ("leathera", "normal"), ROGUE % ("leathera", "orm"), 0.0, 1.0, BODY_SPECULAR),
    "rogue_leatherb": (ROGUE % ("leatherb", "albedo"), ROGUE % ("leatherb", "normal"), ROGUE % ("leatherb", "orm"), 0.0, 1.0, BODY_SPECULAR),
    "rogue_metal": (ROGUE % ("metal", "albedo"), ROGUE % ("metal", "normal"), ROGUE % ("metal", "orm"), 0.0, 1.0, BODY_SPECULAR),
    "rogue_cloth": (ROGUE % ("cloth", "albedo"), ROGUE % ("cloth", "normal"), ROGUE % ("cloth", "orm"), 0.0, 1.0, BODY_SPECULAR),  # the body reference's pants and shirt
    "sword": (SWORD % "albedo", SWORD % "normal", SWORD % "metal_rough", 1.0, 1.0, 0.5),
    "shield": (SHIELD % "albedo", SHIELD % "normal", SHIELD % "metal_rough", 1.0, 1.0, 0.5),
}


def image(path, colour):
    full = os.path.join(PROJECT, path)
    found = next((i for i in bpy.data.images if os.path.normpath(bpy.path.abspath(i.filepath)) == full), None)
    found = found or bpy.data.images.load(full, check_existing=True)
    found.colorspace_settings.name = 'sRGB' if colour else 'Non-Color'
    return found


def build(material, albedo, normal, packed, metallic, roughness, specular):
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()
    out = nodes.new('ShaderNodeOutputMaterial')
    out.location = (600, 0)
    bsdf = nodes.new('ShaderNodeBsdfPrincipled')
    bsdf.location = (300, 0)
    links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Specular IOR Level"].default_value = specular

    def texture(path, colour, y):
        node = nodes.new('ShaderNodeTexImage')
        node.image = image(path, colour)
        node.location = (-600, y)
        return node

    links.new(texture(albedo, True, 300).outputs["Color"], bsdf.inputs["Base Color"])
    split = nodes.new('ShaderNodeSeparateColor')
    split.location = (-300, 0)
    links.new(texture(packed, False, 0).outputs["Color"], split.inputs["Color"])
    for channel, socket, value, y in (("Green", "Roughness", roughness, 100), ("Blue", "Metallic", metallic, -100)):
        times = nodes.new('ShaderNodeMath')
        times.operation = 'MULTIPLY'
        times.location = (0, y)
        times.inputs[1].default_value = value
        links.new(split.outputs[channel], times.inputs[0])
        links.new(times.outputs["Value"], bsdf.inputs[socket])
    bump = nodes.new('ShaderNodeNormalMap')
    bump.location = (0, -300)
    links.new(texture(normal, False, -300).outputs["Color"], bump.inputs["Color"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])


def apply():
    done = []
    for material in bpy.data.materials:
        entry = MATERIALS.get(material.name.split(".")[0])
        if entry:
            build(material, *entry)
            done.append(material.name)
    try:
        for area in bpy.context.screen.areas:
            if area.type == 'VIEW_3D':
                area.spaces[0].shading.type = 'MATERIAL'
    except Exception:
        pass
    print("FP_ARMS materials: %s" % ", ".join(sorted(done)))


if __name__ == "__main__":
    apply()
