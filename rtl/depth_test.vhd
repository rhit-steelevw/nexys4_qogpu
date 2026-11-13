-- depth_test.vhd : E4 depth test (VHDL-2008, Vivado xsim)
-- E3 gives depth + UV; E4 only decides pass/drop and forwards x, y, z, U, V to E5
-- (E5 reads the texture colour from BRAM). One fragment in flight. Issues a depth read through the memory-controller
-- interface, waits for the response (any latency >= 1 cycle, any amount of
-- mem_req_ready stall), then compares. Pass rule: pz < stored_z (equal -> drop).
-- Memory contract:
--   * request is accepted on the clock edge where mem_req_valid = '1' and
--     mem_req_ready = '1'; mem_req_addr is held stable until then.
--   * mem_rsp_valid is a 1-cycle pulse, at least 1 cycle AFTER the accept edge
--     (same-cycle / combinational response is not supported).
--   * rst_n must also reset the memory controller. If only this block were
--     reset while a read is in flight, the late reply could be taken as the
--     answer to the NEXT fragment.
-- Read-after-write: a passed fragment's depth is written later by E6 (after E5).
-- Before reading the depth of a new fragment E4 waits in HOLD until wr_pending = '0',
-- i.e. no passed fragment is still in E5/E6 waiting for its depth write to be
-- ACCEPTED by the memory controller. Top level: wr_pending = E5 busy or E6 busy.
-- (pass_ready alone is NOT enough: with E5 between E4 and E6 it only says that E5
-- is free.) Needs a controller that keeps commands in order (a read accepted after
-- a write sees the new data).
-- Fragments outside the 320x240 frame are dropped without a memory read
-- (guard against an upstream clipping bug; remove if E3 guarantees clipping).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity depth_test is
  generic (DEPTH_W : natural := 8;
           UV_W    : natural := 8);   -- texture coordinate width (confirm with E3/E5)
  port (
    clk, rst_n : in std_logic;
    frag_valid : in std_logic; frag_ready : out std_logic;
    px : in unsigned(8 downto 0); py : in unsigned(7 downto 0);
    pz : in unsigned(DEPTH_W-1 downto 0); pu, pv : in unsigned(UV_W-1 downto 0);
    -- memory-controller interface (depth read)
    mem_req_valid : out std_logic; mem_req_ready : in std_logic; mem_req_addr : out unsigned(16 downto 0);
    mem_rsp_valid : in std_logic; mem_rsp_data : in std_logic_vector(DEPTH_W-1 downto 0);
    -- to write-back (E6)
    pass_valid : out std_logic; pass_ready : in std_logic;
    pass_x : out unsigned(8 downto 0); pass_y : out unsigned(7 downto 0);
    pass_z : out unsigned(DEPTH_W-1 downto 0); pass_u, pass_v : out unsigned(UV_W-1 downto 0);
    -- high while an earlier passed fragment's depth write is not yet accepted (E5 + E6)
    wr_pending : in std_logic
  );
end entity;

architecture rtl of depth_test is
  type state_t is (IDLE, HOLD, REQ, WAIT_RSP, COMPARE, PASS, DROP);
  signal state    : state_t := IDLE;
  signal x_r      : unsigned(8 downto 0);
  signal y_r      : unsigned(7 downto 0);
  signal z_r      : unsigned(DEPTH_W-1 downto 0);
  signal u_r, v_r : unsigned(UV_W-1 downto 0);
  signal addr_r   : unsigned(16 downto 0);
  signal stored_r : unsigned(DEPTH_W-1 downto 0);
  constant FRAME_W : natural := 320;
  constant FRAME_H : natural := 240;
begin
  frag_ready    <= '1' when state = IDLE else '0';
  mem_req_valid <= '1' when state = REQ  else '0';
  mem_req_addr  <= addr_r;
  pass_valid    <= '1' when state = PASS else '0';
  pass_x        <= x_r;
  pass_y        <= y_r;
  pass_z        <= z_r;
  pass_u        <= u_r;
  pass_v        <= v_r;

  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        state <= IDLE;
      else
        case state is
          when IDLE =>
            if frag_valid = '1' then
              x_r    <= px;
              y_r    <= py;
              z_r    <= pz;
              u_r    <= pu;
              v_r    <= pv;
              -- addr = py*320 + px  (in range: max 239*320+319 = 76799 < 2^17)
              addr_r <= resize(py * to_unsigned(FRAME_W, 9), 17) + resize(px, 17);
              if px < to_unsigned(FRAME_W, 9) and py < to_unsigned(FRAME_H, 8) then
                state <= HOLD;
              else
                state <= DROP;              -- off-screen: never touch memory
              end if;
            end if;

          when HOLD =>                      -- earlier depth write must be accepted first
            if wr_pending = '0' then
              state <= REQ;
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
            else
              state <= DROP;                -- equal or farther: keep old pixel
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
