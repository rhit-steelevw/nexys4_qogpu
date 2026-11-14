-- gpu_top.vhd : Integration 2 top level (RQ-99), SKELETON
--
-- Block A (command_controller) -> scene_stub -> draw_pipeline (D..E6)
-- clear_engine + draw_pipeline share the framebuffer write port and, through
-- mem_mux, the depth-buffer memory controller (BRAM back-end).
-- VGA scan-out reads the framebuffer. One clock (100 MHz), pixel enable 1 in 4.
--
-- Port list is FROZEN (plan, Workstream 4): the board wrapper is built against it,
-- and the Integration 1 bring-up gpu_top exposes the same ports with tie-offs.
-- Merge order: close RQ-96 (gpu_top_tb on the bring-up version) BEFORE replacing it.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;
use work.qogpu_fx_pkg.all;
use work.mem_if_pkg.all;

entity gpu_top is
  generic (
    DEPTH_W : positive range 1 to 16 := 8;   -- later from RQ-113's board config package
    INTERP  : boolean := true;
    PIX_DIV : positive := 4                  -- 100 MHz -> 25 MHz pixel enable
  );
  port (
    clk, rst_n         : in  std_logic;
    start_i            : in  std_logic;      -- one-cycle pulse: clear + draw one frame
    vga_r, vga_g       : out std_logic_vector(2 downto 0);
    vga_b              : out std_logic_vector(1 downto 0);
    vga_hs_n, vga_vs_n : out std_logic;
    busy_o             : out std_logic;      -- Block A busy
    frame_done_o       : out std_logic;      -- sticky: last frame finished, cleared by start_i
    error_o            : out std_logic       -- Block A sticky error
  );
end entity gpu_top;

architecture rtl of gpu_top is
  signal rst_meta, rst_s : std_logic := '0';
  signal pix_cnt : natural range 0 to PIX_DIV - 1 := 0;
  signal pix_en  : std_logic;

  -- Block A
  signal a_clr_start, a_clr_done : std_logic;
  signal a_clr_color : pixel_t;
  signal a_clr_depth : std_logic_vector(DEPTH_W - 1 downto 0);
  signal a_fs_valid, a_fs_ready : std_logic;
  signal a_done, a_busy, a_err  : std_logic;

  -- scene_stub -> draw_pipeline
  signal s_valid, s_ready : std_logic;
  signal s_v0x, s_v0y, s_v1x, s_v1y, s_v2x, s_v2y : q16_t;
  signal s_z0, s_z1, s_z2 : unsigned(DEPTH_W - 1 downto 0);
  signal s_color : pixel_t;
  signal s_last  : std_logic;

  -- draw_pipeline
  signal dp_fb_we : std_logic;
  signal dp_fb_addr : fb_addr_t;
  signal dp_fb_data : pixel_t;
  signal dp_frame_done : std_logic;

  -- clear engine
  signal ce_fb_we : std_logic;
  signal ce_fb_addr : fb_addr_t;
  signal ce_fb_data : pixel_t;
  signal ce_req_v, ce_req_we : std_logic;
  signal ce_req_addr  : fb_addr_t;
  signal ce_req_wdata : std_logic_vector(DEPTH_W - 1 downto 0);

  -- memory
  signal reqs     : mem_req_array_t(0 to MEM_CLIENTS - 1);
  signal readys   : std_logic_vector(0 to MEM_CLIENTS - 1);
  signal mem_req  : mem_req_t;
  signal mem_req_ready, mem_ready : std_logic;
  signal mem_rsp  : mem_rsp_t;

  -- framebuffer
  signal fb_we : std_logic;
  signal fb_waddr, scan_addr : fb_addr_t;
  signal fb_wdata, scan_data : pixel_t;

  signal frame_done_r : std_logic := '0';
begin
  process (clk)
  begin
    if rising_edge(clk) then
      rst_meta <= rst_n;
      rst_s    <= rst_meta;
    end if;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if rst_s = '0' or pix_cnt = PIX_DIV - 1 then
        pix_cnt <= 0;
      else
        pix_cnt <= pix_cnt + 1;
      end if;
    end if;
  end process;
  pix_en <= '1' when pix_cnt = PIX_DIV - 1 else '0';

  u_a : entity work.command_controller
    generic map (DEPTH_W => DEPTH_W)
    port map (
      clk_i => clk, rstn_i => rst_s,
      start_i => start_i, busy_o => a_busy, done_o => a_done,
      err_i => '0', error_o => a_err,                       -- no Block B yet
      rot_wr_en_i => '0', rot_wr_sel_i => (others => '0'), rot_wr_data_i => (others => '0'),
      cos_x_o => open, sin_x_o => open, cos_y_o => open,
      sin_y_o => open, cos_z_o => open, sin_z_o => open,
      clr_start_o => a_clr_start, clr_color_o => a_clr_color,
      clr_depth_o => a_clr_depth, clr_done_i => a_clr_done,
      frame_start_valid_o => a_fs_valid, frame_start_ready_i => a_fs_ready,
      frame_done_i => dp_frame_done
    );

  u_stub : entity work.scene_stub
    generic map (DEPTH_W => DEPTH_W)
    port map (
      clk_i => clk, rst_n_i => rst_s,
      start_valid_i => a_fs_valid, start_ready_o => a_fs_ready,
      out_valid_o => s_valid, out_ready_i => s_ready,
      out_v0_x_o => s_v0x, out_v0_y_o => s_v0y,
      out_v1_x_o => s_v1x, out_v1_y_o => s_v1y,
      out_v2_x_o => s_v2x, out_v2_y_o => s_v2y,
      out_v0_z_o => s_z0, out_v1_z_o => s_z1, out_v2_z_o => s_z2,
      out_color_o => s_color, out_last_o => s_last
    );

  u_dp : entity work.draw_pipeline
    generic map (DEPTH_W => DEPTH_W, INTERP => INTERP)
    port map (
      clk_i => clk, rst_n_i => rst_s,
      in_valid_i => s_valid, in_ready_o => s_ready,
      in_v0_x_i => s_v0x, in_v0_y_i => s_v0y,
      in_v1_x_i => s_v1x, in_v1_y_i => s_v1y,
      in_v2_x_i => s_v2x, in_v2_y_i => s_v2y,
      in_v0_z_i => s_z0, in_v1_z_i => s_z1, in_v2_z_i => s_z2,
      in_color_i => s_color, in_last_i => s_last,
      fb_we_o => dp_fb_we, fb_waddr_o => dp_fb_addr, fb_wdata_o => dp_fb_data,
      e4_req_o => reqs(MEM_CLIENT_E4), e4_req_ready_i => readys(MEM_CLIENT_E4),
      mem_rsp_i => mem_rsp,
      e6_req_o => reqs(MEM_CLIENT_E6), e6_req_ready_i => readys(MEM_CLIENT_E6),
      tri_done_o => open, frame_done_o => dp_frame_done
    );

  u_clear : entity work.clear_engine
    generic map (DEPTH_W => DEPTH_W)
    port map (
      clk_i => clk, rst_n_i => rst_s,
      start_i => a_clr_start, color_i => a_clr_color, depth_i => a_clr_depth,
      busy_o => open, done_o => a_clr_done,
      fb_we_o => ce_fb_we, fb_waddr_o => ce_fb_addr, fb_wdata_o => ce_fb_data,
      mem_ready_i => mem_ready,
      mem_req_valid_o => ce_req_v, mem_req_ready_i => readys(MEM_CLIENT_CLEAR),
      mem_req_we_o => ce_req_we, mem_req_addr_o => ce_req_addr,
      mem_req_wdata_o => ce_req_wdata
    );
  reqs(MEM_CLIENT_CLEAR) <= (valid => ce_req_v, we => ce_req_we, addr => ce_req_addr,
                             wdata => to_mem_data(ce_req_wdata));

  u_mux : entity work.mem_mux
    port map (reqs_i => reqs, readys_o => readys, req_o => mem_req, req_ready_i => mem_req_ready);

  u_mem : entity work.mem_ctrl_bram
    generic map (DEPTH_W => DEPTH_W)
    port map (clk_i => clk, rst_n_i => rst_s,
              req => mem_req, req_ready => mem_req_ready, rsp => mem_rsp, mem_ready => mem_ready);

  -- framebuffer write port: clear engine first, then draw_pipeline (they never overlap:
  -- Block A starts the stub only after clr_done)
  fb_we    <= ce_fb_we or dp_fb_we;
  fb_waddr <= ce_fb_addr when ce_fb_we = '1' else dp_fb_addr;
  fb_wdata <= ce_fb_data when ce_fb_we = '1' else dp_fb_data;

  u_fb : entity work.framebuffer
    port map (clk_i => clk, wr_en_i => fb_we, wr_addr_i => fb_waddr, wr_data_i => fb_wdata,
              rd_addr_i => scan_addr, rd_data_o => scan_data);

  u_vga : entity work.vga_scanout
    port map (clk_i => clk, rst_n_i => rst_s, pix_en_i => pix_en,
              fb_raddr_o => scan_addr, fb_rdata_i => scan_data,
              vga_r_o => vga_r, vga_g_o => vga_g, vga_b_o => vga_b,
              vga_hs_n_o => vga_hs_n, vga_vs_n_o => vga_vs_n);

  -- status
  process (clk)
  begin
    if rising_edge(clk) then
      if rst_s = '0' or start_i = '1' then
        frame_done_r <= '0';
      elsif a_done = '1' then
        frame_done_r <= '1';
      end if;
    end if;
  end process;

  busy_o       <= a_busy;
  frame_done_o <= frame_done_r;
  error_o      <= a_err;

  -- synthesis translate_off
  checks : process (clk)
  begin
    if rising_edge(clk) then
      assert not (mem_req.valid = '1' and mem_ready = '0')
        report "gpu_top: request raised before mem_ready" severity failure;
      assert not (ce_fb_we = '1' and dp_fb_we = '1')
        report "gpu_top: clear engine and draw_pipeline both write the framebuffer" severity failure;
    end if;
  end process;
  -- synthesis translate_on
end architecture rtl;
