-- depth_test.vhd : E4 depth test (VHDL-2008, Vivado xsim)
--   * marker side-band (kill/eot/eof) and per-fragment color
--   * HOLD state and the wr_pending port REMOVED. Depth hazards are handled by
--     docs/spec/memory_interface.md rules H1-H4 and rule 11, and nowhere else:
--       within a triangle E1 visits each pixel once, so a read never targets a
--       word with a write still pending from the same triangle; between triangles
--       E1 waits for E6's tri_done (H1, gate in rasterizer.vhd); everything that
--       is accepted takes effect in acceptance order (rule 11).
--
-- One fragment in flight. Issues a depth read through the memory-controller
-- interface, waits for the response (any latency >= 1 cycle, any amount of
-- mem_req_ready stall), then compares. Pass rule: pz < stored_z (equal -> drop).
-- rst_n must also reset the memory controller (a late reply to a read accepted
-- before reset must never be taken as the answer for the next fragment).
--
-- A fragment that carries eot or eof is never dropped before E6
-- (H2/H3 need the marker to reach E6; H4 guarantees one exists per triangle).
--   frag_kill = 1 or off screen : no memory read.
--        marker (eot or eof)    -> PASS with pass_kill = 1
--        no marker              -> DROP
--   depth fails, marker         -> PASS with pass_kill = 1
--   depth fails, no marker      -> DROP
--   depth passes                -> PASS with pass_kill = 0
-- Inputs have defaults; tb/depth_test_tb.vhd only loses its wr_pending line.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity depth_test is
  generic (DEPTH_W : natural := 8;
           UV_W    : natural := 8);
  port (
    clk, rst_n : in std_logic;
    frag_valid : in std_logic; frag_ready : out std_logic;
    px : in unsigned(8 downto 0); py : in unsigned(7 downto 0);
    pz : in unsigned(DEPTH_W-1 downto 0); pu, pv : in unsigned(UV_W-1 downto 0);
    frag_kill  : in std_logic := '0';                                   
    frag_eot   : in std_logic := '0';                                   
    frag_eof   : in std_logic := '0';                                   
    frag_color : in std_logic_vector(7 downto 0) := (others => '0');    -- RGB332
    -- memory-controller interface (depth read)
    mem_req_valid : out std_logic; mem_req_ready : in std_logic; mem_req_addr : out unsigned(16 downto 0);
    mem_rsp_valid : in std_logic; mem_rsp_data : in std_logic_vector(DEPTH_W-1 downto 0);
    -- to write-back (E6)
    pass_valid : out std_logic; pass_ready : in std_logic;
    pass_x : out unsigned(8 downto 0); pass_y : out unsigned(7 downto 0);
    pass_z : out unsigned(DEPTH_W-1 downto 0); pass_u, pass_v : out unsigned(UV_W-1 downto 0);
    pass_kill  : out std_logic;                                         
    pass_eot   : out std_logic;                                         
    pass_eof   : out std_logic;                                         
    pass_color : out std_logic_vector(7 downto 0)                       
    -- wr_pending REMOVED: see header
  );
end entity;

architecture rtl of depth_test is
  type state_t is (IDLE, REQ, WAIT_RSP, COMPARE, PASS, DROP);          -- no HOLD
  signal state    : state_t := IDLE;
  signal x_r      : unsigned(8 downto 0);
  signal y_r      : unsigned(7 downto 0);
  signal z_r      : unsigned(DEPTH_W-1 downto 0);
  signal u_r, v_r : unsigned(UV_W-1 downto 0);
  signal addr_r   : unsigned(16 downto 0);
  signal stored_r : unsigned(DEPTH_W-1 downto 0);
  signal kill_r, eot_r, eof_r : std_logic := '0';                       
  signal color_r  : std_logic_vector(7 downto 0) := (others => '0');    
  signal marker_r : std_logic;                                          
  constant FRAME_W : natural := 320;
  constant FRAME_H : natural := 240;
begin
  marker_r <= eot_r or eof_r;

  frag_ready    <= '1' when state = IDLE else '0';
  mem_req_valid <= '1' when state = REQ  else '0';
  mem_req_addr  <= addr_r;
  pass_valid    <= '1' when state = PASS else '0';
  pass_x        <= x_r;
  pass_y        <= y_r;
  pass_z        <= z_r;
  pass_u        <= u_r;
  pass_v        <= v_r;
  pass_kill     <= kill_r;                                              
  pass_eot      <= eot_r;                                               
  pass_eof      <= eof_r;                                               
  pass_color    <= color_r;                                             

  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        state <= IDLE;
      else
        case state is
          when IDLE =>
            if frag_valid = '1' then
              x_r <= px; y_r <= py; z_r <= pz; u_r <= pu; v_r <= pv;
              eot_r   <= frag_eot;                                      
              eof_r   <= frag_eof;                                      
              color_r <= frag_color;                                    
              kill_r  <= '0';                                           
              addr_r  <= resize(py * to_unsigned(FRAME_W, 9), 17) + resize(px, 17);
              if frag_kill = '1' or px >= to_unsigned(FRAME_W, 9) or py >= to_unsigned(FRAME_H, 8) then
                if frag_eot = '1' or frag_eof = '1' then
                  kill_r <= '1';
                  state  <= PASS;
                else
                  state <= DROP;
                end if;
              else
                state <= REQ;
              end if;
            end if;

          when REQ =>                       -- hold valid/addr until accepted
            if mem_req_ready = '1' then
              state <= WAIT_RSP;
            end if;

          when WAIT_RSP =>                  -- no latency assumption
            if mem_rsp_valid = '1' then
              stored_r <= unsigned(mem_rsp_data);
              state    <= COMPARE;
            end if;

          when COMPARE =>
            if z_r < stored_r then
              state <= PASS;
            elsif marker_r = '1' then
              kill_r <= '1';
              state  <= PASS;
            else
              state <= DROP;
            end if;

          when PASS =>                      -- hold data until E6 takes it
            if pass_ready = '1' then
              state <= IDLE;
            end if;

          when DROP =>
            state <= IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
