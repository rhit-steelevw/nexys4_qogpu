-- draw_pipeline.vhd : D -> E1..E3 -> E4 -> E6 (RQ-99, Integration 2)
--
-- Input side  = Block C's output interface (tri_setup's input). scene_stub drives
--               it now; Block C replaces the stub in RQ-100 with no change here.
-- Output side = framebuffer write port + two memory client ports (records from
--               mem_if_pkg) for gpu_top's mem_mux, + tri_done / frame_done.
-- One clock domain, synchronous active-low reset shared by every stage.
-- E4 must share its reset with the memory controller (depth_test.vhd header).
-- Depth hazards: memory_interface.md H1-H4 only. E6's tri_done closes the H1 gate
-- in front of E1; E4 does not wait on E6 (no wr_pending).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;
use work.qogpu_fx_pkg.all;
use work.raster_pkg.all;
use work.mem_if_pkg.all;
use work.shade_pkg.all;

entity draw_pipeline is
  generic (
    DEPTH_W : positive := 8;
    INTERP  : boolean  := true;   -- false: E3 passes z0 (flat-depth scenes only, timing fallback)
    SHADE   : boolean  := false   -- depth-cue colour between E4 and E6 (E5 slot)
  );
  port (
    clk_i   : in  std_logic;
    rst_n_i : in  std_logic;
    -- from Block C / scene_stub
    in_valid_i : in  std_logic;
    in_ready_o : out std_logic;
    in_v0_x_i, in_v0_y_i : in q16_t;
    in_v1_x_i, in_v1_y_i : in q16_t;
    in_v2_x_i, in_v2_y_i : in q16_t;
    in_v0_z_i, in_v1_z_i, in_v2_z_i : in unsigned(DEPTH_W - 1 downto 0);
    in_color_i : in  pixel_t;
    in_last_i  : in  std_logic;
    -- framebuffer write
    fb_we_o    : out std_logic;
    fb_waddr_o : out fb_addr_t;
    fb_wdata_o : out pixel_t;
    -- memory: E4 depth read
    e4_req_o       : out mem_req_t;
    e4_req_ready_i : in  std_logic;
    mem_rsp_i      : in  mem_rsp_t;
    -- memory: E6 depth write
    e6_req_o       : out mem_req_t;
    e6_req_ready_i : in  std_logic;
    -- status
    tri_done_o   : out std_logic;
    frame_done_o : out std_logic
  );
end entity;

architecture rtl of draw_pipeline is
  -- D -> E1..E3
  signal d_valid, d_ready : std_logic;
  signal d_tri            : tri_t;
  -- E3 -> E4
  signal r_valid, r_ready : std_logic;
  signal r_px             : fb_x_t;
  signal r_py             : fb_y_t;
  signal r_z              : unsigned(DEPTH_W - 1 downto 0);
  signal r_kill, r_eot, r_eof : std_logic;
  signal r_color          : pixel_t;
  -- E4 -> E6
  signal p_valid, p_ready : std_logic;
  signal p_x              : unsigned(8 downto 0);
  signal p_y              : unsigned(7 downto 0);
  signal p_z              : unsigned(DEPTH_W - 1 downto 0);
  signal p_kill, p_eot, p_eof : std_logic;
  signal p_color          : std_logic_vector(7 downto 0);
  signal e6_color         : std_logic_vector(7 downto 0);     -- after the E5 slot
  -- E4 memory side
  signal e4_v    : std_logic;
  signal e4_addr : unsigned(16 downto 0);
  -- E6 memory side
  signal e6_v, e6_we : std_logic;
  signal e6_addr     : unsigned(16 downto 0);
  signal e6_wdata    : std_logic_vector(DEPTH_W - 1 downto 0);
  signal tri_done    : std_logic;    -- E6 -> rasterizer H1 gate (memory_interface.md H1/H2)
  constant UV_ZERO   : unsigned(7 downto 0) := (others => '0');
begin
  u_d : entity work.tri_setup
    generic map (DEPTH_W => DEPTH_W)
    port map (
      clk_i => clk_i, rst_n_i => rst_n_i,
      in_valid_i => in_valid_i, in_ready_o => in_ready_o,
      in_v0_x_i => in_v0_x_i, in_v0_y_i => in_v0_y_i,
      in_v1_x_i => in_v1_x_i, in_v1_y_i => in_v1_y_i,
      in_v2_x_i => in_v2_x_i, in_v2_y_i => in_v2_y_i,
      in_v0_z_i => in_v0_z_i, in_v1_z_i => in_v1_z_i, in_v2_z_i => in_v2_z_i,
      in_color_i => in_color_i, in_last_i => in_last_i,
      out_valid_o => d_valid, out_ready_i => d_ready, out_tri_o => d_tri
    );

  u_raster : entity work.rasterizer
    generic map (DEPTH_W => DEPTH_W, INTERP => INTERP)
    port map (
      clk_i => clk_i, rst_n_i => rst_n_i,
      in_valid_i => d_valid, in_ready_o => d_ready, in_tri_i => d_tri,
      out_valid_o => r_valid, out_ready_i => r_ready,
      out_px_o => r_px, out_py_o => r_py, out_z_o => r_z,
      out_kill_o => r_kill, out_eot_o => r_eot, out_eof_o => r_eof,
      out_color_o => r_color,
      tri_done_i => tri_done
    );

  u_e4 : entity work.depth_test
    generic map (DEPTH_W => DEPTH_W)
    port map (
      clk => clk_i, rst_n => rst_n_i,
      frag_valid => r_valid, frag_ready => r_ready,
      px => r_px, py => r_py, pz => r_z, pu => UV_ZERO, pv => UV_ZERO,
      frag_kill => r_kill, frag_eot => r_eot, frag_eof => r_eof, frag_color => r_color,
      mem_req_valid => e4_v, mem_req_ready => e4_req_ready_i, mem_req_addr => e4_addr,
      mem_rsp_valid => mem_rsp_i.valid,
      mem_rsp_data  => from_mem_data(mem_rsp_i.rdata, DEPTH_W),
      pass_valid => p_valid, pass_ready => p_ready,
      pass_x => p_x, pass_y => p_y, pass_z => p_z, pass_u => open, pass_v => open,
      pass_kill => p_kill, pass_eot => p_eot, pass_eof => p_eof, pass_color => p_color
    );

  -- E5 slot: depth cue (MVP shading); texturing replaces it later.
  e6_color <= depth_cue(p_color, p_z) when SHADE else p_color;

  u_e6 : entity work.writeback
    generic map (DEPTH_W => DEPTH_W)
    port map (
      clk => clk_i, rst_n => rst_n_i,
      pass_valid => p_valid, pass_ready => p_ready,
      pass_x => p_x, pass_y => p_y, pass_z => p_z, pass_color => e6_color,
      pass_kill => p_kill, pass_eot => p_eot, pass_eof => p_eof,
      fb_we => fb_we_o, fb_waddr => fb_waddr_o, fb_wdata => fb_wdata_o,
      mem_req_valid => e6_v, mem_req_ready => e6_req_ready_i, mem_req_we => e6_we,
      mem_req_addr => e6_addr, mem_req_wdata => e6_wdata,
      tri_done => tri_done, frame_done => frame_done_o
    );
  tri_done_o <= tri_done;

  -- pack the client ports into mem_if_pkg records
  e4_req_o <= (valid => e4_v, we => '0', addr => e4_addr, wdata => (others => '0'));
  e6_req_o <= (valid => e6_v, we => e6_we, addr => e6_addr, wdata => to_mem_data(e6_wdata));

  -- synthesis translate_off
  checks : process (clk_i)
    variable in_flight : boolean := false;
    variable last_seen : natural := 0;
    variable frames    : natural := 0;
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        in_flight := false;
        last_seen := 0;
        frames    := 0;
      else
        if tri_done = '1' then
          assert in_flight report "draw_pipeline: tri_done with no triangle in flight" severity error;
          in_flight := false;
        end if;
        if d_valid = '1' and d_ready = '1' then
          assert not in_flight report "draw_pipeline: H1 violated, triangle accepted before tri_done" severity error;
          in_flight := true;
        end if;
        if in_valid_i = '1' and in_ready_o = '1' and in_last_i = '1' then
          last_seen := last_seen + 1;
        end if;
        if frame_done_o = '1' then
          frames := frames + 1;
          assert frames <= last_seen report "draw_pipeline: frame_done without a last triangle" severity error;
        end if;
      end if;
    end if;
  end process;
  -- synthesis translate_on
end architecture;
