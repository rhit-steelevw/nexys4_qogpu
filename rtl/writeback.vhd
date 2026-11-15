-- E6 write-back: color -> BRAM framebuffer, depth -> memory controller.
--
--   kill = 0 : fb_we pulses once; depth write held until mem_req_ready (as before).
--              eot/eof latched; tri_done/frame_done pulse the cycle AFTER the accept.
--   kill = 1 : no fb write, no memory request, stays ready (1-clock transfer);
--              tri_done/frame_done pulse on the next cycle.
--   eot and eof together pulse both outputs on the same cycle.
--   These are rules H2/H3 of docs/spec/memory_interface.md: tri_done goes back to
--   the rasterizer's H1 gate, frame_done to Block A. A killed eot is only accepted
--   while idle, i.e. once every earlier depth write has been accepted.
-- New inputs default to '0' so tb/tb_writeback.vhd still compiles unchanged.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity writeback is
  generic (DEPTH_W : natural := 8);
  port (
    clk, rst_n : in std_logic;
    pass_valid : in std_logic; pass_ready : out std_logic;
    pass_x : in unsigned(8 downto 0); pass_y : in unsigned(7 downto 0);
    pass_z : in unsigned(DEPTH_W-1 downto 0); pass_color : in std_logic_vector(7 downto 0);
    fb_we : out std_logic; fb_waddr : out unsigned(16 downto 0); fb_wdata : out std_logic_vector(7 downto 0);
    mem_req_valid : out std_logic; mem_req_ready : in std_logic; mem_req_we : out std_logic;
    mem_req_addr : out unsigned(16 downto 0); mem_req_wdata : out std_logic_vector(DEPTH_W-1 downto 0);
    -- Ports go LAST: tb/tb_writeback.vhd binds by position, so trailing
    -- defaulted inputs and unconnected outputs keep it compiling unchanged.
    pass_kill  : in std_logic := '0';   
    pass_eot   : in std_logic := '0';   
    pass_eof   : in std_logic := '0';   
    tri_done   : out std_logic;         -- one-cycle pulse, to rasterizer (H1/H2)
    frame_done : out std_logic          -- one-cycle pulse, to Block A (H3)
  );
end entity;

architecture rtl of writeback is
  signal busy_r  : std_logic := '0';
  signal fb_we_r : std_logic := '0';
  signal req_v_r : std_logic := '0';
  signal addr_r  : unsigned(16 downto 0) := (others => '0');
  signal addr_in : unsigned(16 downto 0);
  signal eot_r, eof_r         : std_logic := '0';   -- markers of the write in flight
  signal tri_done_r, frame_done_r : std_logic := '0';  
begin
  addr_in <= resize(pass_y * to_unsigned(320, 9), 17) + resize(pass_x, 17);

  assert not (busy_r = '0' and pass_valid = '1' and pass_kill = '0' and addr_in >= 76800)
    report "writeback: fragment outside 320x240" severity error;

  pass_ready    <= not busy_r;
  fb_we         <= fb_we_r;
  fb_waddr      <= addr_r;
  mem_req_valid <= req_v_r;
  mem_req_we    <= '1';
  mem_req_addr  <= addr_r;
  tri_done      <= tri_done_r;          
  frame_done    <= frame_done_r;        

  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        busy_r <= '0'; fb_we_r <= '0'; req_v_r <= '0';
        tri_done_r <= '0'; frame_done_r <= '0';
      else
        fb_we_r      <= '0';
        tri_done_r   <= '0';
        frame_done_r <= '0';
        if busy_r = '0' then
          if pass_valid = '1' then
            if pass_kill = '1' then
              tri_done_r   <= pass_eot;
              frame_done_r <= pass_eof;
            else
              addr_r        <= addr_in;
              fb_wdata      <= pass_color;
              mem_req_wdata <= std_logic_vector(pass_z);
              eot_r         <= pass_eot;
              eof_r         <= pass_eof;
              fb_we_r       <= '1';
              req_v_r       <= '1';
              busy_r        <= '1';
            end if;
          end if;
        elsif mem_req_ready = '1' then
          req_v_r <= '0';
          busy_r  <= '0';
          tri_done_r   <= eot_r;
          frame_done_r <= eof_r;
        end if;
      end if;
    end if;
  end process;
end architecture;
