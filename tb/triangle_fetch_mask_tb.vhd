-- triangle_fetch FACE_MASK checks: selected faces only, ascending, last on the
-- highest selected face. One checker per mask.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fetch_mask_check is
  generic (
    MASK      : std_logic_vector(1 to 12);
    EXP_FACES : integer_vector
  );
  port (
    clk  : in  std_logic;
    done : out boolean
  );
end entity;

architecture sim of fetch_mask_check is
  type ids_t is array (0 to 2) of unsigned(31 downto 0);
  type face_t is array (0 to 2) of natural;
  type faces_t is array (1 to 12) of face_t;
  constant FACES : faces_t := (
    (1,2,4), (3,4,2), (5,6,8), (7,8,6),
    (9,10,12), (11,12,10), (13,14,16), (15,16,14),
    (17,18,20), (19,20,18), (21,22,24), (23,24,22)
  );

  signal rstn, start_valid, ready : std_logic := '0';
  signal start_ready, valid, last, err : std_logic;
  signal addr : unsigned(9 downto 0);
  signal rom_data : std_logic_vector(31 downto 0);
  signal ids : ids_t;
  signal ax, ay, az, bx, by, bz, cx, cy, cz : signed(31 downto 0);
begin
  rom : entity work.asset_memory
    port map (clk => clk, addr => addr, data => rom_data);

  dut : entity work.triangle_fetch
    generic map (FACE_MASK => MASK)
    port map (
      clk_i => clk, rstn_i => rstn,
      frame_start_valid_i => start_valid, frame_start_ready_o => start_ready,
      mem_addr_o => addr, mem_data_i => rom_data,
      triangle_valid_o => valid, triangle_ready_i => ready,
      triangle_last_o => last, err_o => err,
      vertex_a_id_o => ids(0), vertex_a_x_o => ax, vertex_a_y_o => ay, vertex_a_z_o => az,
      vertex_b_id_o => ids(1), vertex_b_x_o => bx, vertex_b_y_o => by, vertex_b_z_o => bz,
      vertex_c_id_o => ids(2), vertex_c_x_o => cx, vertex_c_y_o => cy, vertex_c_z_o => cz
    );

  check : process
    variable n : natural := 0;
  begin
    done <= false;
    rstn <= '0';
    for i in 1 to 5 loop wait until rising_edge(clk); end loop;
    rstn <= '1';
    wait until rising_edge(clk);
    start_valid <= '1';
    wait until rising_edge(clk);
    start_valid <= '0';
    ready <= '1';

    while n < EXP_FACES'length loop
      wait until rising_edge(clk);
      if valid = '1' and ready = '1' then
        for s in 0 to 2 loop
          assert ids(s) = to_unsigned(FACES(EXP_FACES(EXP_FACES'low + n))(s), 32)
            report "wrong vertex ID, triangle " & integer'image(n) &
                   ", slot " & integer'image(s) & ", got " &
                   integer'image(to_integer(ids(s))) severity failure;
        end loop;
        assert abs(ax) = 37837 and abs(ay) = 37837 and abs(az) = 37837
          report "wrong vertex A coordinates, triangle " & integer'image(n) severity failure;
        assert (last = '1') = (n = EXP_FACES'length - 1)
          report "last marker on wrong triangle, triangle " & integer'image(n) severity failure;
        n := n + 1;
      end if;
      assert err = '0' report "B faulted" severity failure;
    end loop;

    for i in 1 to 200 loop
      wait until rising_edge(clk);
      assert valid = '0' and err = '0'
        report "extra triangle after the last one" severity failure;
    end loop;
    done <= true;
    wait;
  end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity triangle_fetch_mask_tb is
end entity;

architecture sim of triangle_fetch_mask_tb is
  signal clk : std_logic := '0';
  signal d1, d2, d3 : boolean;
  signal stop : boolean := false;
begin
  clk <= not clk after 5 ns when not stop;

  -- faces 1 and 12
  c1 : entity work.fetch_mask_check
    generic map (MASK => "100000000001", EXP_FACES => (1, 12))
    port map (clk => clk, done => d1);

  -- faces 2 and 10: last moves to face 10
  c2 : entity work.fetch_mask_check
    generic map (MASK => "010000000100", EXP_FACES => (2, 10))
    port map (clk => clk, done => d2);

  -- face 6 only
  c3 : entity work.fetch_mask_check
    generic map (MASK => "000001000000", EXP_FACES => (0 => 6))
    port map (clk => clk, done => d3);

  process
  begin
    wait until d1 and d2 and d3 for 1 ms;
    assert d1 and d2 and d3 report "FAIL: mask checks timed out" severity failure;
    report "triangle_fetch_mask_tb: ALL TESTS PASSED";
    stop <= true;
    wait;
  end process;
end architecture;
