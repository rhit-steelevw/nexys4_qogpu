from pathlib import Path

# Six vertices: X, Y, Z in signed 16.16 hexadecimal.
vertices = [
    (0xFFFF4000, 0x00008000, 0xFFFF8000),  # A
    (0x00004000, 0x00008000, 0xFFFF8000),  # B
    (0xFFFFC000, 0xFFFF4000, 0xFFFF8000),  # C
    (0xFFFFC000, 0x0000C000, 0x00008000),  # D
    (0x0000C000, 0x0000C000, 0x00008000),  # E
    (0x00004000, 0xFFFF8000, 0x00008000),  # F
]

# The current map uses 1-based vertex indices.
faces = [(1, 2, 3), (4, 5, 6)]

# The existing loader expects exactly 1,024 32-bit words.
words = [0] * 1024

# Current map: 6 words per vertex.
# The remaining 3 fields (Xt, Yt, TextureID) stay zero for now.
for index, (x, y, z) in enumerate(vertices):
    base = index * 6
    words[base:base + 3] = [x, y, z]

# Current map: face indices start at word 144.
for index, face in enumerate(faces):
    base = 144 + index * 3
    words[base:base + 3] = face

output = Path(__file__).with_name("scene_two_triangles.mem")
with output.open("w", encoding="ascii", newline="\n") as file:
    for word in words:
        file.write(f"{word:032b}\n")

print(f"Wrote {len(words)} binary words to {output}")