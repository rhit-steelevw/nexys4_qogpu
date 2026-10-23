\# QOGPU MVP Block Diagram and Interface List



RQ-79 · Sprint 1 · Owner: Vance Steele



\*\*Scope:\*\* two overlapping flat-colored triangles, vertices given directly (no rotation, no texturing).



\*\*Flow:\*\* A → B → C → D → E1 → E2 → E3 → E4 → E6 → memory controller → VGA (E5 skipped until texturing)



\- 16.16 signed fixed point in the shared buffer

\- Screen space is 320x240 after Block C

\- RGB332 framebuffer in BRAM (320x240x8), 2x scaled to 640x480 by VGA

\- Depth buffer behind the memory controller, `DEPTH\_W` = 8 by default

\- valid/ready between blocks, one clock domain (`clk\_i`, `rstn\_i` active low)



\*\*Handshake:\*\* a transfer happens on the rising edge where `valid` and `ready` are both high. A source must not wait for `ready` before raising `valid`, and must hold its payload steady until the transfer happens.



\## Summary



| Block | Inputs | Outputs | Handshake | Owner task |

|---|---|---|---|---|

| A command/status + shared buffer | XBUS (optional), start, frame done, error | face index, vertex buffer data, clear request | XBUS (Wishbone) to CPU; valid/ready to B | RQ-86, RQ-102 |

| B fetch | face index from A | 3 vertices (x,y,z) + color | valid/ready | RQ-108 |

| C transform (single) | 3 vertices, 16.16 normalized | 3 vertices, screen space + depth | valid/ready | RQ-91 |

| D setup | 3 screen-space vertices | bounding box, edge coefficients, area | valid/ready | RQ-92 |

| E1 scan | triangle setup | pixel (x,y) | valid/ready | RQ-93 |

| E2 coverage | pixel (x,y) | pixel + inside flag + edge weights | valid/ready | RQ-93 |

| E3 depth interp | pixel + edge weights | pixel + z | valid/ready | RQ-93 |

| E4 depth test | pixel + z | pixel + pass/fail | valid/ready; memory req/rsp | RQ-94 |

| E6 write-back | passing pixel + z | color write, depth write, done | valid/ready; memory req | RQ-95 |

| Memory controller | requests from clear, E4, E6 | read data | req/rsp (valid/ready) | RQ-106, RQ-107, RQ-109 |

| Framebuffer | writes from clear/E6 | pixel data to VGA | fixed 1-cycle BRAM read | RQ-84 |

| Clear engine | clear request from A | framebuffer + depth fill | memory req; done pulse | RQ-89 |

| VGA | framebuffer data | hsync, vsync, RGB | fixed 1-cycle BRAM read | RQ-83, RQ-87 |



\## Ports by block



All blocks also have `clk\_i` and `rstn\_i`. Widths marked \*(unc)\* are unconfirmed until the numeric contract (RQ-38) is done.



\### Block A: command/status + shared buffer



| Port | Dir | Width | Description |

|---|---|---|---|

| `xbus\_adr\_i` | in | 32 | XBUS address (only used when `CPU\_EN`) |

| `xbus\_dat\_i` | in | 32 | XBUS write data |

| `xbus\_we\_i` | in | 1 | XBUS write enable |

| `xbus\_sel\_i` | in | 4 | XBUS byte select |

| `xbus\_stb\_i` | in | 1 | XBUS strobe |

| `xbus\_cyc\_i` | in | 1 | XBUS cycle |

| `xbus\_dat\_o` | out | 32 | XBUS read data |

| `xbus\_ack\_o` | out | 1 | XBUS acknowledge |

| `xbus\_err\_o` | out | 1 | XBUS error |

| `start\_i` | in | 1 | Start pulse when no CPU (button or auto-start) |

| `face\_valid\_o` | out | 1 | Face index valid |

| `face\_ready\_i` | in | 1 | B ready for a face |

| `face\_idx\_o` | out | 8 | Face number |

| `face\_last\_o` | out | 1 | Last face in frame |

| `buf\_raddr\_i` | in | `BUF\_ADDR\_W` | Shared buffer read address from B |

| `buf\_rdata\_o` | out | 32 | Shared buffer read data (1-cycle latency) |

| `num\_verts\_o` | out | 8 | Vertex count, for B's index check |

| `clr\_start\_o` | out | 1 | Start clear pulse |

| `clr\_color\_o` | out | 8 | Clear color (RGB332) |

| `clr\_depth\_o` | out | `DEPTH\_W` | Clear depth value |

| `clr\_done\_i` | in | 1 | Clear finished pulse |

| `frame\_done\_i` | in | 1 | From E6: last pixel of last triangle written |

| `err\_i` | in | 1 | From B: bad vertex index |



Shared buffer is preloaded from `INIT\_FILE`. Register offsets and buffer layout are in the memory map (RQ-80).



\### Block B: fetch



| Port | Dir | Width | Description |

|---|---|---|---|

| `in\_valid\_i` | in | 1 | Face index valid |

| `in\_ready\_o` | out | 1 | Ready for a face |

| `in\_face\_idx\_i` | in | 8 | Face number |

| `in\_last\_i` | in | 1 | Last face |

| `buf\_raddr\_o` | out | `BUF\_ADDR\_W` | Shared buffer read address |

| `buf\_rdata\_i` | in | 32 | Shared buffer read data |

| `num\_verts\_i` | in | 8 | Vertex count |

| `out\_valid\_o` | out | 1 | Triangle valid |

| `out\_ready\_i` | in | 1 | C ready |

| `out\_v0\_x\_o`, `out\_v0\_y\_o`, `out\_v0\_z\_o` | out | 32 each | Vertex 0, 16.16 |

| `out\_v1\_x\_o`, `out\_v1\_y\_o`, `out\_v1\_z\_o` | out | 32 each | Vertex 1, 16.16 |

| `out\_v2\_x\_o`, `out\_v2\_y\_o`, `out\_v2\_z\_o` | out | 32 each | Vertex 2, 16.16 |

| `out\_color\_o` | out | 8 | Face color, RGB332 |

| `out\_last\_o` | out | 1 | Last triangle |

| `err\_o` | out | 1 | Vertex index ≥ `num\_verts\_i` |



\### Block C: transform (single)



Scale/offset to 320x240 and depth range mapping (z −1..1 to 0..2^`DEPTH\_W`−1), serial over the 3 vertices.



| Port | Dir | Width | Description |

|---|---|---|---|

| `in\_valid\_i` / `in\_ready\_o` | in / out | 1 | Handshake from B |

| `in\_v{0,1,2}\_{x,y,z}\_i` | in | 32 each | Vertices, 16.16 normalized |

| `in\_color\_i` | in | 8 | Face color |

| `in\_last\_i` | in | 1 | Last triangle |

| `out\_valid\_o` / `out\_ready\_i` | out / in | 1 | Handshake to D |

| `out\_v{0,1,2}\_x\_o` | out | 32 each | Screen x, 16.16 (0..320) |

| `out\_v{0,1,2}\_y\_o` | out | 32 each | Screen y, 16.16 (0..240) |

| `out\_v{0,1,2}\_z\_o` | out | `DEPTH\_W` each | Mapped depth |

| `out\_color\_o` | out | 8 | Face color |

| `out\_last\_o` | out | 1 | Last triangle |



\### Block D: triangle setup



| Port | Dir | Width | Description |

|---|---|---|---|

| `in\_valid\_i` / `in\_ready\_o` | in / out | 1 | Handshake from C |

| `in\_v{0,1,2}\_{x,y}\_i` | in | 32 each | Screen coordinates |

| `in\_v{0,1,2}\_z\_i` | in | `DEPTH\_W` each | Depth |

| `in\_color\_i`, `in\_last\_i` | in | 8, 1 | Pass-through |

| `out\_valid\_o` / `out\_ready\_i` | out / in | 1 | Handshake to E1 |

| `out\_xmin\_o`, `out\_xmax\_o` | out | 9 | Bounding box x, clamped to screen |

| `out\_ymin\_o`, `out\_ymax\_o` | out | 8 | Bounding box y, clamped to screen |

| `out\_e{0,1,2}\_a\_o`, `out\_e{0,1,2}\_b\_o` | out | 11 each \*(unc)\* | Edge function x/y coefficients |

| `out\_e{0,1,2}\_c\_o` | out | 24 each \*(unc)\* | Edge function constants |

| `out\_area\_o` | out | 24 \*(unc)\* | Signed area |

| `out\_z{0,1,2}\_o` | out | `DEPTH\_W` each | Vertex depths |

| `out\_color\_o`, `out\_last\_o` | out | 8, 1 | Pass-through |

| `out\_empty\_o` | out | 1 | Zero-area triangle; only sent when it is the last one, so the frame still finishes |



\### E1: pixel scan



| Port | Dir | Width | Description |

|---|---|---|---|

| `in\_valid\_i` / `in\_ready\_o` | in / out | 1 | Handshake from D |

| `in\_\*` | in | — | All D outputs |

| `out\_valid\_o` / `out\_ready\_i` | out / in | 1 | Handshake to E2 |

| `out\_px\_o` | out | 9 | Pixel x |

| `out\_py\_o` | out | 8 | Pixel y |

| `out\_eot\_o` | out | 1 | Last pixel of this triangle |

| `out\_eof\_o` | out | 1 | Last pixel of the frame |

| `out\_tri\_o` | out | — | Held copy of D's outputs for E2, E3, E6 |



\### E2: coverage



| Port | Dir | Width | Description |

|---|---|---|---|

| `in\_valid\_i` / `in\_ready\_o` | in / out | 1 | Handshake from E1 |

| `in\_px\_i`, `in\_py\_i` | in | 9, 8 | Pixel |

| `in\_eot\_i`, `in\_eof\_i` | in | 1, 1 | Markers |

| `in\_tri\_i` | in | — | Edge coefficients |

| `out\_valid\_o` / `out\_ready\_i` | out / in | 1 | Handshake to E3 |

| `out\_px\_o`, `out\_py\_o` | out | 9, 8 | Pixel |

| `out\_w{0,1,2}\_o` | out | 24 each \*(unc)\* | Edge function values |

| `out\_kill\_o` | out | 1 | Pixel outside triangle |

| `out\_eot\_o`, `out\_eof\_o` | out | 1, 1 | Markers |



\### E3: depth interpolation



| Port | Dir | Width | Description |

|---|---|---|---|

| `in\_valid\_i` / `in\_ready\_o` | in / out | 1 | Handshake from E2 |

| `in\_px\_i`, `in\_py\_i`, `in\_w{0,1,2}\_i` | in | — | From E2 |

| `in\_kill\_i`, `in\_eot\_i`, `in\_eof\_i` | in | 1 each | From E2 |

| `in\_tri\_i` | in | — | z0..z2, area |

| `out\_valid\_o` / `out\_ready\_i` | out / in | 1 | Handshake to E4 |

| `out\_px\_o`, `out\_py\_o` | out | 9, 8 | Pixel |

| `out\_z\_o` | out | `DEPTH\_W` | Interpolated depth |

| `out\_kill\_o`, `out\_eot\_o`, `out\_eof\_o` | out | 1 each | Pass-through |



\### E4: depth test



| Port | Dir | Width | Description |

|---|---|---|---|

| `in\_valid\_i` / `in\_ready\_o` | in / out | 1 | Handshake from E3 |

| `in\_px\_i`, `in\_py\_i`, `in\_z\_i` | in | 9, 8, `DEPTH\_W` | Pixel and depth |

| `in\_kill\_i`, `in\_eot\_i`, `in\_eof\_i` | in | 1 each | Markers |

| `mem\_\*` | — | — | Memory client port, read only (see below) |

| `out\_valid\_o` / `out\_ready\_i` | out / in | 1 | Handshake to E6 |

| `out\_px\_o`, `out\_py\_o`, `out\_z\_o` | out | 9, 8, `DEPTH\_W` | Pixel and depth |

| `out\_kill\_o` | out | 1 | Set if killed or depth test failed |

| `out\_eot\_o`, `out\_eof\_o` | out | 1 each | Markers |



Skips the read when `in\_kill\_i` is set



\### E6: write-back



| Port | Dir | Width | Description |

|---|---|---|---|

| `in\_valid\_i` / `in\_ready\_o` | in / out | 1 | Handshake from E4 |

| `in\_px\_i`, `in\_py\_i`, `in\_z\_i` | in | 9, 8, `DEPTH\_W` | Pixel and depth |

| `in\_kill\_i`, `in\_eot\_i`, `in\_eof\_i` | in | 1 each | Markers |

| `in\_tri\_i` | in | — | Face color |

| `fb\_we\_o` | out | 1 | Framebuffer write enable |

| `fb\_waddr\_o` | out | 17 | Framebuffer address (y\*320 + x) |

| `fb\_wdata\_o` | out | 8 | Color, RGB332 |

| `mem\_\*` | — | — | Memory client port, write only (see below) |

| `tri\_done\_o` | out | 1 | Pulse on the `eot` pixel |

| `frame\_done\_o` | out | 1 | Pulse on the `eof` pixel, to A |



\### Memory controller: client port (one per client)



Clients: clear engine (write), E4 (read), E6 (write), latency and ordering rules go in the memory interface



| Port | Dir (client side) | Width | Description |

|---|---|---|---|

| `mem\_req\_valid\_o` | out | 1 | Request valid |

| `mem\_req\_ready\_i` | in | 1 | Controller accepts request |

| `mem\_req\_we\_o` | out | 1 | 1 = write, 0 = read |

| `mem\_req\_addr\_o` | out | 17 | Depth word address (y\*320 + x) |

| `mem\_req\_wdata\_o` | out | `DEPTH\_W` | Write data |

| `mem\_rsp\_valid\_i` | in | 1 | Read data valid |

| `mem\_rsp\_ready\_o` | out | 1 | Client accepts read data |

| `mem\_rsp\_rdata\_i` | in | `DEPTH\_W` | Read data |



The controller's backend side (BRAM or SRAM pins) is chosen by `MEM\_BACKEND` and is not seen by the pipeline



\### Framebuffer



| Port | Dir | Width | Description |

|---|---|---|---|

| `wr\_en\_i` | in | 1 | Write enable (from clear engine or E6) |

| `wr\_addr\_i` | in | 17 | Write address |

| `wr\_data\_i` | in | 8 | RGB332 |

| `rd\_addr\_i` | in | 17 | Read address from VGA |

| `rd\_data\_o` | out | 8 | Read data, 1-cycle latency |



\### Clear engine



| Port | Dir | Width | Description |

|---|---|---|---|

| `start\_i` | in | 1 | From A |

| `color\_i` | in | 8 | Clear color |

| `depth\_i` | in | `DEPTH\_W` | Clear depth |

| `fb\_we\_o`, `fb\_waddr\_o`, `fb\_wdata\_o` | out | 1, 17, 8 | Framebuffer write |

| `mem\_\*` | — | — | Memory client port, write only |

| `done\_o` | out | 1 | Pulse when both buffers are filled |



\### VGA



| Port | Dir | Width | Description |

|---|---|---|---|

| `fb\_raddr\_o` | out | 17 | Framebuffer address, 2x2 doubled |

| `fb\_rdata\_i` | in | 8 | RGB332 |

| `vga\_hs\_o` | out | 1 | Horizontal sync |

| `vga\_vs\_o` | out | 1 | Vertical sync |

| `vga\_r\_o` | out | 3 | Red |

| `vga\_g\_o` | out | 3 | Green |

| `vga\_b\_o` | out | 2 | Blue |



640x480@60 timing from a pixel enable on the system clock (one clock domain).

