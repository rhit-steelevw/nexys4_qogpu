-- gpu_top.vhd
-- Last modified: 11/14/2026
-- top level with clear engine, framebuffer, VGA and BRAM back-end

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;
use work.mem_if_pkg.all;
use work.bringup_pkg.all;

entity gpu_top is
  port (
    clk, rst_n         : in  std_logic;
    vga_r, vga_g       : out std_logic_vector(2 downto 0);
    vga_b              : out std_logic_vector(1 downto 0);
    vga_hs_n, vga_vs_n : out std_logic
  );
end entity gpu_top;

architecture rtl of gpu_top is

  constant DEPTH_W  : positive := BRINGUP_DEPTH_W;
  constant PIX_DIV  : positive := 4;   -- 100 MHz clock -> 25 MHz pixel enable

  -- reset (button -> two flops, then used synchronously everywhere)
  signal rst_meta, rst_s : std_logic := '0';

  -- pixel enable
  signal pix_cnt : natural range 0 to PIX_DIV - 1 := 0;
  signal pix_en  : std_logic;

  -- clear engine
  signal ce_start, ce_busy, ce_done : std_logic := '0';
  signal ce_depth     : std_logic_vector(DEPTH_W - 1 downto 0);
  signal ce_fb_we     : std_logic;
  signal ce_fb_addr   : fb_addr_t;
  signal ce_fb_data   : pixel_t;
  signal ce_req       : mem_req_t;
  signal ce_req_v     : std_logic;
  signal ce_req_we    : std_logic;
  signal ce_req_addr  : fb_addr_t;
  signal ce_req_wdata : std_logic_vector(DEPTH_W - 1 downto 0);

  -- E6 write-back 
  signal e6_valid, e6_ready : std_logic := '0';
  signal e6_x     : unsigned(8 downto 0) := (others => '0');
  signal e6_y     : unsigned(7 downto 0) := (others => '0');
  signal e6_z     : unsigned(DEPTH_W - 1 downto 0) := (others => '0');
  signal e6_color : pixel_t := (others => '0');
  signal e6_fb_we     : std_logic;
  signal e6_fb_addr   : fb_addr_t;
  signal e6_fb_data   : pixel_t;
  signal e6_req       : mem_req_t;
  signal e6_req_v     : std_logic;
  signal e6_req_we    : std_logic;
  signal e6_req_addr  : fb_addr_t;
  signal e6_req_wdata : std_logic_vector(DEPTH_W - 1 downto 0);

  -- E4 slot 
  signal e4_req : mem_req_t := MEM_REQ_IDLE;

  -- framebuffer
  signal fb_we    : std_logic;
  signal fb_waddr : fb_addr_t;
  signal fb_wdata : pixel_t;
  signal scan_addr : fb_addr_t;
  signal scan_data : pixel_t;

  -- memory controller port, after the priority mux
  signal reqs      : mem_req_array_t(0 to MEM_CLIENTS - 1);
  signal grant     : natural range 0 to MEM_CLIENTS - 1;
  signal mem_req   : mem_req_t;
  signal mem_req_ready, mem_ready : std_logic;
  signal mem_rsp   : mem_rsp_t;
  signal ready_clr, ready_e6, ready_e4 : std_logic;

  -- bring-up sequencer
  type seq_t is (Q_START, Q_CLEAR_WAIT,
                 Q_FRAG_PRESENT, Q_FRAG_ACCEPT, Q_FRAG_IDLE,
                 Q_RD_REQ, Q_RD_ACCEPT, Q_RD_RSP, Q_DONE);
  signal seq : seq_t := Q_START;
  signal idx : natural range 0 to 15 := 0;

begin

  ---------------------------------------------------------------------------
  -- reset sync and pixel enable
  ---------------------------------------------------------------------------
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

  ---------------------------------------------------------------------------
  -- modules
  ---------------------------------------------------------------------------
  u_fb : entity work.framebuffer
    port map (
      clk_i => clk, wr_en_i => fb_we, wr_addr_i => fb_waddr,
      wr_data_i => fb_wdata, rd_addr_i => scan_addr, rd_data_o => scan_data
    );

  u_vga : entity work.vga_scanout
    port map (
      clk_i => clk, rst_n_i => rst_s, pix_en_i => pix_en,
      fb_raddr_o => scan_addr, fb_rdata_i => scan_data,
      vga_r_o => vga_r, vga_g_o => vga_g, vga_b_o => vga_b,
      vga_hs_n_o => vga_hs_n, vga_vs_n_o => vga_vs_n
    );

  ce_depth <= depth_clear(DEPTH_W);   -- rule 14: clear to 2^D - 1

  u_clear : entity work.clear_engine
    generic map (DEPTH_W => DEPTH_W)
    port map (
      clk_i => clk, rst_n_i => rst_s,
      start_i => ce_start, color_i => BRINGUP_COLOR, depth_i => ce_depth,
      busy_o => ce_busy, done_o => ce_done,
      fb_we_o => ce_fb_we, fb_waddr_o => ce_fb_addr, fb_wdata_o => ce_fb_data,
      mem_ready_i => mem_ready,
      mem_req_valid_o => ce_req_v, mem_req_ready_i => ready_clr,
      mem_req_we_o => ce_req_we, mem_req_addr_o => ce_req_addr,
      mem_req_wdata_o => ce_req_wdata
    );

  u_e6 : entity work.writeback
    generic map (DEPTH_W => DEPTH_W)
    port map (
      clk => clk, rst_n => rst_s,
      pass_valid => e6_valid, pass_ready => e6_ready,
      pass_x => e6_x, pass_y => e6_y, pass_z => e6_z, pass_color => e6_color,
      fb_we => e6_fb_we, fb_waddr => e6_fb_addr, fb_wdata => e6_fb_data,
      mem_req_valid => e6_req_v, mem_req_ready => ready_e6,
      mem_req_we => e6_req_we, mem_req_addr => e6_req_addr,
      mem_req_wdata => e6_req_wdata
    );

  u_mem : entity work.mem_ctrl_bram
    generic map (DEPTH_W => DEPTH_W)
    port map (
      clk_i => clk, rst_n_i => rst_s,
      req => mem_req, req_ready => mem_req_ready,
      rsp => mem_rsp, mem_ready => mem_ready
    );

  ---------------------------------------------------------------------------
  -- framebuffer write port: clear engine first, then E6 (replaced by N4)
  ---------------------------------------------------------------------------
  fb_we    <= ce_fb_we or e6_fb_we;
  fb_waddr <= ce_fb_addr when ce_fb_we = '1' else e6_fb_addr;
  fb_wdata <= ce_fb_data when ce_fb_we = '1' else e6_fb_data;

  ---------------------------------------------------------------------------
  -- memory controller port: clear, then E6, then E4 (replaced by N4)
  -- a client's ready may depend on the other clients' valid, never on its own
  ---------------------------------------------------------------------------
  ce_req <= (valid => ce_req_v, we => ce_req_we, addr => ce_req_addr,
             wdata => to_mem_data(ce_req_wdata));
  e6_req <= (valid => e6_req_v, we => e6_req_we, addr => e6_req_addr,
             wdata => to_mem_data(e6_req_wdata));

  reqs(MEM_CLIENT_CLEAR) <= ce_req;
  reqs(MEM_CLIENT_E6)    <= e6_req;
  reqs(MEM_CLIENT_E4)    <= e4_req;

  pick : process (all)
  begin
    grant <= MEM_CLIENT_CLEAR;
    for i in MEM_CLIENTS - 1 downto 0 loop   -- lowest index is assigned last, so it wins
      if reqs(i).valid = '1' then
        grant <= i;
      end if;
    end loop;
  end process;

  mem_req   <= reqs(grant);
  ready_clr <= mem_req_ready when grant = MEM_CLIENT_CLEAR else '0';
  ready_e6  <= mem_req_ready when grant = MEM_CLIENT_E6    else '0';
  ready_e4  <= mem_req_ready when grant = MEM_CLIENT_E4    else '0';

  -- synthesis translate_off
  checks : process (clk)
  begin
    if rising_edge(clk) then
      assert not (mem_req.valid = '1' and mem_ready = '0')
        report "gpu_top: request raised before mem_ready" severity failure;
      assert not (ce_fb_we = '1' and e6_fb_we = '1')
        report "gpu_top: clear engine and E6 both write the framebuffer" severity failure;
    end if;
  end process;
  -- synthesis translate_on

  ---------------------------------------------------------------------------
  -- bring-up sequencer (stands in for Block A and E4, goes away in Integration 2)
  ---------------------------------------------------------------------------
  sequencer : process (clk)
  begin
    if rising_edge(clk) then
      ce_start <= '0';
      if rst_s = '0' then
        seq      <= Q_START;
        idx      <= 0;
        e6_valid <= '0';
        e4_req   <= MEM_REQ_IDLE;
      else
        case seq is
          -- 1. clear (color buffer + depth buffer). The engine waits for
          --    mem_ready by itself, so start can go out right after reset
          when Q_START =>
            ce_start <= '1';
            seq      <= Q_CLEAR_WAIT;

          when Q_CLEAR_WAIT =>
            if ce_done = '1' then
              idx <= 0;
              seq <= Q_FRAG_PRESENT;
            end if;

          -- 2. fragments through E6, one at a time
          when Q_FRAG_PRESENT =>
            e6_x     <= to_unsigned(TEST_X(idx), 9);
            e6_y     <= to_unsigned(TEST_Y(idx), 8);
            e6_z     <= to_unsigned(TEST_Z(idx), DEPTH_W);
            e6_color <= TEST_COLOR(idx);
            e6_valid <= '1';
            seq      <= Q_FRAG_ACCEPT;

          when Q_FRAG_ACCEPT =>
            if e6_ready = '1' then          -- transfer happens on this edge
              e6_valid <= '0';
              seq      <= Q_FRAG_IDLE;
            end if;

          when Q_FRAG_IDLE =>               -- E6 is ready again once its depth write was accepted
            if e6_ready = '1' then
              if idx = N_TEST_PIX - 1 then
                idx <= 0;
                seq <= Q_RD_REQ;
              else
                idx <= idx + 1;
                seq <= Q_FRAG_PRESENT;
              end if;
            end if;

          -- 3. depth readback through the E4 slot
          when Q_RD_REQ =>
            e4_req <= (valid => '1', we => '0',
                       addr  => to_unsigned(depth_check_addr(idx), MEM_ADDR_W),
                       wdata => (others => '0'));
            seq    <= Q_RD_ACCEPT;

          when Q_RD_ACCEPT =>
            if ready_e4 = '1' then
              e4_req.valid <= '0';
              seq          <= Q_RD_RSP;
            end if;

          when Q_RD_RSP =>
            if mem_rsp.valid = '1' then
              -- synthesis translate_off
              assert mem_rsp.rdata(DEPTH_W - 1 downto 0) = depth_check_exp(idx)
                report "gpu_top bring-up: depth word " &
                       integer'image(depth_check_addr(idx)) & " wrong"
                severity failure;
              -- synthesis translate_on
              if idx = N_DEPTH_CHECKS - 1 then
                -- synthesis translate_off
                report "gpu_top bring-up: clear, E6 writes and depth readback done";
                -- synthesis translate_on
                seq <= Q_DONE;
              else
                idx <= idx + 1;
                seq <= Q_RD_REQ;
              end if;
            end if;

          when Q_DONE =>
            null;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;