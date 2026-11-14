-- Framebuffer + depth-buffer clear engine (RQ-89, depth port for RQ-96)
-- SKELETON for Integration 2, step 0. gpu_top on main already instantiates
-- this port list; the committed clear_engine.vhd (253f61e) lacks it.
--
-- Fills all FB_PIXELS color words and depth words in lock-step:
--   IDLE --start--> WAIT_MEM --mem_ready_i--> RUN --last accepted--> FINISH --> IDLE
--   RUN: mem_req_valid_o = 1 with addr = cnt; on the edge where mem_req_ready_i = 1
--        the framebuffer word at cnt is written (fb_we_o = 1 on that cycle) and cnt steps.
--   So a memory stall (DDR2) also holds the framebuffer write. BRAM never stalls:
--   76,800 clocks per clear.
-- * start is only accepted in IDLE; color and depth are latched then.
-- * done_o pulses once, after the last depth write is ACCEPTED (in-order controller,
--   memory interface rule 11: later reads see it).
-- * Reset is synchronous, active low.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;

entity clear_engine is
  generic (DEPTH_W : positive range 1 to 16 := 8);
  port (
    clk_i      : in  std_logic;
    rst_n_i    : in  std_logic;
    start_i    : in  std_logic;
    color_i    : in  pixel_t;
    depth_i    : in  std_logic_vector(DEPTH_W - 1 downto 0);
    busy_o     : out std_logic;
    done_o     : out std_logic;
    -- framebuffer write port
    fb_we_o    : out std_logic;
    fb_waddr_o : out fb_addr_t;
    fb_wdata_o : out pixel_t;
    -- memory controller client port, write only
    mem_ready_i     : in  std_logic;   -- controller init done (mem_ready)
    mem_req_valid_o : out std_logic;
    mem_req_ready_i : in  std_logic;
    mem_req_we_o    : out std_logic;   -- always '1'
    mem_req_addr_o  : out fb_addr_t;
    mem_req_wdata_o : out std_logic_vector(DEPTH_W - 1 downto 0)
  );
end entity;

architecture rtl of clear_engine is
  type state_t is (IDLE, WAIT_MEM, RUN, FINISH);
  signal state   : state_t := IDLE;
  signal cnt     : fb_addr_t := (others => '0');
  signal color_r : pixel_t := (others => '0');
  signal depth_r : std_logic_vector(DEPTH_W - 1 downto 0) := (others => '0');
  signal accept  : std_logic;
  constant LAST_ADDR : fb_addr_t := to_unsigned(FB_PIXELS - 1, FB_ADDR_W);
begin
  accept <= '1' when state = RUN and mem_req_ready_i = '1' else '0';

  process (clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        state <= IDLE;
        cnt   <= (others => '0');
      else
        case state is
          when IDLE =>
            if start_i = '1' then
              color_r <= color_i;
              depth_r <= depth_i;
              cnt     <= (others => '0');
              state   <= WAIT_MEM;
            end if;
          when WAIT_MEM =>
            if mem_ready_i = '1' then
              state <= RUN;
            end if;
          when RUN =>
            if accept = '1' then
              if cnt = LAST_ADDR then
                state <= FINISH;
              else
                cnt <= cnt + 1;
              end if;
            end if;
          when FINISH =>
            state <= IDLE;
        end case;
      end if;
    end if;
  end process;

  busy_o          <= '0' when state = IDLE else '1';
  done_o          <= '1' when state = FINISH else '0';
  fb_we_o         <= accept;            -- framebuffer word written with its depth word
  fb_waddr_o      <= cnt;
  fb_wdata_o      <= color_r;
  mem_req_valid_o <= '1' when state = RUN else '0';
  mem_req_we_o    <= '1';
  mem_req_addr_o  <= cnt;
  mem_req_wdata_o <= depth_r;
end architecture;
