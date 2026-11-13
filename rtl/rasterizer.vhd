-- Rasterizer: E1 + E2 (raster_scan) and E3 (depth_interp), RQ-93
--
-- What RQ-99 instantiates between Block D (tri_setup) and E4. The output port
-- list is E4's input list in docs/architecture/mvp_block_diagram.md, plus
-- out_color_o: E6 takes color from each fragment, not from a held tri_t.
--
-- INTERP = false: E3 passes z_0 (bit-exact for the MVP scene only, where each
-- triangle has one depth).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;
use work.raster_pkg.all;

entity rasterizer is
  generic (
    DEPTH_W : positive := 8;
    INTERP  : boolean  := true
  );
  port (
    clk_i       : in  std_logic;
    rst_n_i     : in  std_logic;
    in_valid_i  : in  std_logic;
    in_ready_o  : out std_logic;
    in_tri_i    : in  tri_t;
    out_valid_o : out std_logic;
    out_ready_i : in  std_logic;
    out_px_o    : out fb_x_t;
    out_py_o    : out fb_y_t;
    out_z_o     : out unsigned(DEPTH_W - 1 downto 0);
    out_kill_o  : out std_logic;
    out_eot_o   : out std_logic;
    out_eof_o   : out std_logic;
    out_color_o : out pixel_t
  );
end entity;

architecture rtl of rasterizer is
  signal s_valid, s_ready : std_logic;
  signal s_scan           : scan_t;
begin
  scan : entity work.raster_scan
    port map (
      clk_i => clk_i, rst_n_i => rst_n_i,
      in_valid_i => in_valid_i, in_ready_o => in_ready_o, in_tri_i => in_tri_i,
      out_valid_o => s_valid, out_ready_i => s_ready, out_scan_o => s_scan
    );

  depth : entity work.depth_interp
    generic map (DEPTH_W => DEPTH_W, INTERP => INTERP)
    port map (
      clk_i => clk_i, rst_n_i => rst_n_i,
      in_valid_i => s_valid, in_ready_o => s_ready, in_scan_i => s_scan,
      out_valid_o => out_valid_o, out_ready_i => out_ready_i,
      out_px_o => out_px_o, out_py_o => out_py_o, out_z_o => out_z_o,
      out_kill_o => out_kill_o, out_eot_o => out_eot_o, out_eof_o => out_eof_o,
      out_color_o => out_color_o
    );
end architecture;
