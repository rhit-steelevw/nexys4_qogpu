# Block B Triangle Fetch

Team 05 — QOGPU Graphics Pipeline

Connor Bodie

11/11/2026

Block B fetches vertex data from BRAM, assembles each triangle in registers, and synchronizes its transfer to the Block C transform stage or stages. It accepts one frame request from Block A and processes all 12 cube faces in order. The current interface is defined by [`triangle_fetch` in block_b.vhd](../../rtl/block_b.vhd).

## Geometry data and memory layout

The prototype uses fixed constants for the [BRAM memory map](../spec/memory_map.md): 24 vertices, 12 triangular faces, a face-table base of word 144, three words per face, and six words per vertex. Each face contains three consecutive 1-based vertex IDs. A vertex ID identifies a vertex record; it is not itself a BRAM address.

For face `f` and vertex slot `s` (0 = A, 1 = B, 2 = C), Block B reads the ID at:

```text
face_word = 144 + 3 * (f - 1) + s
```

After validating that the full 32-bit ID is in 1–24, Block B computes the vertex base and reads its coordinates:

```text
vertex_base = 6 * (vertex_id - 1)
X address   = vertex_base + 0
Y address   = vertex_base + 1
Z address   = vertex_base + 2
```

For face 1, the ID words are 144, 145, and 146. The supplied cube image contains IDs 1, 2, and 4 at those addresses. Block B fetches XYZ for vertex A first, then repeats the ID and coordinate reads for B and C. The six-word vertex stride includes UV coordinates and a texture ID, but the current fetcher skips those fields. It does not fetch textures or generate a face color.

## Registers and transfer to Block C

Each completed face occupies twelve 32-bit registers: three unsigned vertex IDs and nine signed 16.16 coordinates. The RTL represents these as the `vertex_ids` and `coordinates` arrays. Their values directly drive the output buses; there is no second copy of the payload in output registers.

Block B asserts `triangle_valid_o` as soon as all three IDs and nine coordinates are assembled. It does not wait for Block C to assert ready before asserting valid. Block C captures the entire triangle on a rising edge where `triangle_valid_o` and `triangle_ready_i` are both high. All twelve payload buses and the last-triangle marker remain stable while valid is high and ready is low.

After acceptance, Block B may reuse its registers to fetch the next face. Block C must therefore retain any accepted data that it still needs for computation. If several C blocks process the three vertices, their receiving logic must coordinate acceptance of the whole triangle through this single handshake.

## BRAM read timing

[asset_memory.vhd](../../rtl/asset_memory.vhd) provides a synchronous 32-bit read port with a 10-bit word address. It has no read-enable, ready, or response-valid signal. Block B supplies the address and captures the returned word at the appropriate clock edge.

The current fetcher uses three states per requested word: issue, wait, and capture. It registers an address at edge N, the ROM samples that address at edge N+1, and Block B captures the result at edge N+2. The same sequence is used for vertex IDs and coordinates. This implements the ROM latency explicitly and avoids capturing the previous word.

Each triangle requires twelve useful reads: three IDs and nine coordinates. The current implementation uses 36 fetch cycles to assemble the payload, followed by the transfer handshake and any wait for Block C. Pipelined reads or multiple triangle buffers can be considered later if this fetch rate limits rendering.

## Signals

All directions are relative to Block B. Inputs are sampled on rising edges of `clk_i`. This implementation has no generics; scene dimensions and layout offsets are internal constants.

| Signal | Direction | Bit width | Description |
| --- | --- | ---: | --- |
| `clk_i` | Input | 1 | Common pipeline clock. |
| `rstn_i` | Input | 1 | Synchronous active-low shared reset. Returns B to idle, clears the error and payload registers, and resets traversal to face 1. |
| `frame_start_valid_i` | Input | 1 | Frame request from A. A holds the request until B accepts it with ready and valid both high. |
| `frame_start_ready_o` | Output | 1 | High while B is idle and able to accept a frame request. Low during fetching, triangle presentation, and fault. |
| `mem_addr_o` | Output | 10 | Unsigned BRAM word address, connected to `asset_memory.addr`. |
| `mem_data_i` | Input | 32 | Returned BRAM word: an unsigned vertex ID or the bit pattern of a signed 16.16 coordinate, depending on the current read. |
| `triangle_valid_o` | Output | 1 | A complete triangle is available. Held high until C accepts it. |
| `triangle_ready_i` | Input | 1 | C can capture the complete triangle. A transfer occurs on a rising edge with ready and valid both high. |
| `triangle_last_o` | Output | 1 | High while presenting face 12. Travels with the triangle and remains stable during backpressure; low outside triangle presentation. |
| `err_o` | Output | 1 | Sticky invalid-vertex-ID error. B stops fetching and requires shared reset before accepting another frame. Connects to A's `err_i`. |
| `vertex_a_id_o` | Output | 32 | Unsigned vertex ID in the first slot of the face, preserved as 1-based. |
| `vertex_a_x_o` | Output | 32 | Vertex A X coordinate, signed 16.16. |
| `vertex_a_y_o` | Output | 32 | Vertex A Y coordinate, signed 16.16. |
| `vertex_a_z_o` | Output | 32 | Vertex A Z coordinate, signed 16.16. |
| `vertex_b_id_o` | Output | 32 | Unsigned vertex ID in the second slot of the face, preserved as 1-based. |
| `vertex_b_x_o` | Output | 32 | Vertex B X coordinate, signed 16.16. |
| `vertex_b_y_o` | Output | 32 | Vertex B Y coordinate, signed 16.16. |
| `vertex_b_z_o` | Output | 32 | Vertex B Z coordinate, signed 16.16. |
| `vertex_c_id_o` | Output | 32 | Unsigned vertex ID in the third slot of the face, preserved as 1-based. |
| `vertex_c_x_o` | Output | 32 | Vertex C X coordinate, signed 16.16. |
| `vertex_c_y_o` | Output | 32 | Vertex C Y coordinate, signed 16.16. |
| `vertex_c_z_o` | Output | 32 | Vertex C Z coordinate, signed 16.16. |

The payload buses may contain incomplete or previously assembled data while `triangle_valid_o` is low. C must capture them only on a valid/ready transfer.

## Frame sequence and errors

1. Accept the frame request from [Block A](block_a.md), which has already cleared the buffers and captured the active rotation.
2. Begin with face 1. Fetch each of its three vertex IDs and the corresponding XYZ coordinates.
3. Present the complete triangle to C and wait for acceptance.
4. Repeat for the next face, preserving face-table order and the vertex order within each face.
5. Mark face 12 as the last triangle and return to idle after C accepts it.

Returning to idle means B has finished fetching, not that the frame has finished rendering. A waits for completion from the downstream pipeline before starting another frame. The last-triangle marker must still reach completion logic if the final triangle is culled or produces no pixels. Rotation coefficients come directly from A and stay unchanged for that frame; B does not store or modify them.

An ID outside 1–24 causes B to enter `FAULT` and assert `err_o`. B checks the full ID before converting it to an integer or computing its vertex address. It does not present the partly assembled triangle as valid. Previously accepted triangles may remain in flight; recovery requires shared pipeline reset rather than a new start request.

## Future geometry support

The fixed cube layout lets us establish correct fetching and synchronization before adding a more versatile asset interface. Other scenes will require configurable vertex and face counts and, where the regions move, configurable base addresses and record strides. This metadata could come from a BRAM header or configuration registers rather than hard-coded offsets.

The current record-based addressing and separation of geometry storage from traversal provide a path to that extension. A future implementation must validate the metadata against memory capacity. Supporting different geometry does not inherently require a new layout if it fits the existing format and configured limits.

The [earlier MVP interface list](mvp_block_diagram.md) describes per-face requests from A and a color output from B. The current implementation instead accepts one request per frame and exposes IDs and XYZ only. Color and texturing interfaces remain integration work.
