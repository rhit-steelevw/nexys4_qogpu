-- Rasterizer: E1 + E2 (raster_scan) and E3 (depth_interp), RQ-93
--
-- What RQ-99 instantiates between Block D (tri_setup) and E4. The output port
-- list is E4's input list in docs/architecture/mvp_block_diagram.md, plus
-- out_color_o: E6 takes color from each fragment, not from a held tri_t.
--
-- INTERP = false: E3 passes z_0 (bit-exact for the MVP scene only, where each
-- triangle has one depth).
--
-- NEW (Integration 2): H1 drain gate, docs/spec/memory_interface.md.
--   H1: E1 does not start the next triangle until it sees tri_done from E6 for
--       the current one. Implemented here, in front of raster_scan, so the
--       bit-exact E1/E2 block is unchanged:
--         tri_in_flight <= '1' on the edge a triangle is accepted from D,
--                          '0' on tri_done_i;
--         D's handshake is masked while tri_in_flight = '1'.
--   H4 (one eot per triangle that enters E1) is what makes this deadlock-free:
--   raster_scan always emits an eot pixel, or the eot/eof marker of an empty
--   last triangle; D drops other empty triangles before they get here.
--   tri_done_i has NO default on purpose: an unconnected gate would hang, and a
--   default of '1' would silently turn H1 off.
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
    out_color_o : out pixel_t;
    tri_done_i  : in  std_logic          -- NEW: from E6 (H1)
  );
end entity;

architecture rtl of rasterizer is
  signal s_valid, s_ready : std_logic;
  signal s_scan           : scan_t;
  signal scan_in_valid, scan_in_ready : std_logic;   -- NEW
  signal tri_in_flight    : std_logic := '0';        -- NEW
begin
  -- NEW: H1 gate (combinational mask; tri_in_flight is a flop, so no loop)
  scan_in_valid <= in_valid_i    and not tri_in_flight;
  in_ready_o    <= scan_in_ready and not tri_in_flight;

  h1 : process (clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        tri_in_flight <= '0';
      else
        if scan_in_valid = '1' and scan_in_ready = '1' then
          tri_in_flight <= '1';
        elsif tri_done_i = '1' then
          tri_in_flight <= '0';
        end if;
        -- synthesis translate_off
        -- accept and tri_done cannot coincide: the gate is closed between them
        assert not (scan_in_valid = '1' and scan_in_ready = '1' and tri_done_i = '1')
          report "rasterizer: H1 violated, triangle accepted on tri_done" severity failure;
        assert not (tri_done_i = '1' and tri_in_flight = '0')
          report "rasterizer: tri_done with no triangle in flight" severity failure;
        -- synthesis translate_on
      end if;
    end if;
  end process;

  scan : entity work.raster_scan
    port map (
      clk_i => clk_i, rst_n_i => rst_n_i,
      in_valid_i => scan_in_valid, in_ready_o => scan_in_ready, in_tri_i => in_tri_i,
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
