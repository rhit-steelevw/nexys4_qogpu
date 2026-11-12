-- Block B: fetch all 12 cube faces from the synchronous asset ROM.
-- Each face is assembled before presentation to C. A transfer occurs on
-- an edge with triangle_valid_o and triangle_ready_i both high.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity triangle_fetch is
  port (
    clk_i  : in std_logic;
    rstn_i : in std_logic; -- Synchronous active-low shared pipeline reset.

    frame_start_valid_i : in std_logic;
    frame_start_ready_o : out std_logic;

    mem_addr_o : out unsigned(9 downto 0);
    mem_data_i : in std_logic_vector(31 downto 0);

    triangle_valid_o : out std_logic;
    triangle_ready_i : in std_logic;
    triangle_last_o  : out std_logic;
    err_o            : out std_logic;

    vertex_a_id_o : out unsigned(31 downto 0);
    vertex_a_x_o  : out signed(31 downto 0);
    vertex_a_y_o  : out signed(31 downto 0);
    vertex_a_z_o  : out signed(31 downto 0);
    vertex_b_id_o : out unsigned(31 downto 0);
    vertex_b_x_o  : out signed(31 downto 0);
    vertex_b_y_o  : out signed(31 downto 0);
    vertex_b_z_o  : out signed(31 downto 0);
    vertex_c_id_o : out unsigned(31 downto 0);
    vertex_c_x_o  : out signed(31 downto 0);
    vertex_c_y_o  : out signed(31 downto 0);
    vertex_c_z_o  : out signed(31 downto 0)
  );
end entity triangle_fetch;

architecture rtl of triangle_fetch is
  constant FACE_COUNT       : positive := 12;
  constant VERTEX_COUNT     : positive := 24;
  constant FACE_BASE        : natural  := 144;
  constant WORDS_PER_FACE   : positive := 3;
  constant WORDS_PER_VERTEX : positive := 6;

  type state_t is (IDLE, ID_ISSUE, ID_WAIT, ID_CAPTURE,
                  COORD_ISSUE, COORD_WAIT, COORD_CAPTURE,
                  PRESENT_TRIANGLE, FAULT);
  signal state : state_t;
  signal face_id     : natural range 1 to FACE_COUNT;
  signal vertex_slot : natural range 0 to 2;
  signal axis        : natural range 0 to 2;
  signal mem_addr_r   : unsigned(9 downto 0);
  signal vertex_base_r : unsigned(9 downto 0);
  signal error_r      : std_logic;

  -- These arrays are the A/B/C ID registers and nine XYZ registers.
  type ids_t is array (0 to 2) of unsigned(31 downto 0);
  type coords_t is array (0 to 2, 0 to 2) of signed(31 downto 0);
  signal vertex_ids : ids_t;
  signal coordinates : coords_t;
begin
  mem_addr_o <= mem_addr_r;
  frame_start_ready_o <= '1' when state = IDLE else '0';
  triangle_valid_o <= '1' when state = PRESENT_TRIANGLE else '0';
  triangle_last_o <= '1' when state = PRESENT_TRIANGLE
                              and face_id = FACE_COUNT else '0';
  err_o <= error_r;

  vertex_a_id_o <= vertex_ids(0);
  vertex_a_x_o <= coordinates(0, 0);
  vertex_a_y_o <= coordinates(0, 1);
  vertex_a_z_o <= coordinates(0, 2);
  vertex_b_id_o <= vertex_ids(1);
  vertex_b_x_o <= coordinates(1, 0);
  vertex_b_y_o <= coordinates(1, 1);
  vertex_b_z_o <= coordinates(1, 2);
  vertex_c_id_o <= vertex_ids(2);
  vertex_c_x_o <= coordinates(2, 0);
  vertex_c_y_o <= coordinates(2, 1);
  vertex_c_z_o <= coordinates(2, 2);

  process (clk_i)
    variable vid : unsigned(31 downto 0);
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        state <= IDLE;
        face_id <= 1;
        vertex_slot <= 0;
        axis <= 0;
        mem_addr_r <= (others => '0');
        vertex_base_r <= (others => '0');
        error_r <= '0';
        vertex_ids <= (others => (others => '0'));
        coordinates <= (others => (others => (others => '0')));
      else
        case state is
          when IDLE =>
            if frame_start_valid_i = '1' then
              face_id <= 1;
              vertex_slot <= 0;
              axis <= 0;
              state <= ID_ISSUE;
            end if;

          when ID_ISSUE =>
            mem_addr_r <= to_unsigned(
              FACE_BASE + WORDS_PER_FACE * (face_id - 1) + vertex_slot,
              mem_addr_r'length);
            state <= ID_WAIT;

          when ID_WAIT =>
            -- ROM samples the newly registered address on this edge.
            -- Its new output is captured by B on the following edge.
            state <= ID_CAPTURE;

          when ID_CAPTURE =>
            vid := unsigned(mem_data_i);
            -- Validate all 32 bits before conversion or address arithmetic.
            if vid >= to_unsigned(1, vid'length)
                and vid <= to_unsigned(VERTEX_COUNT, vid'length) then
              vertex_ids(vertex_slot) <= vid;
              vertex_base_r <= to_unsigned(
                WORDS_PER_VERTEX * (to_integer(vid) - 1),
                vertex_base_r'length);
              axis <= 0;
              state <= COORD_ISSUE;
            else
              error_r <= '1';
              state <= FAULT;
            end if;

          when COORD_ISSUE =>
            mem_addr_r <= vertex_base_r + to_unsigned(axis, mem_addr_r'length);
            state <= COORD_WAIT;

          when COORD_WAIT =>
            state <= COORD_CAPTURE;

          when COORD_CAPTURE =>
            coordinates(vertex_slot, axis) <= signed(mem_data_i);
            if axis < 2 then
              axis <= axis + 1;
              state <= COORD_ISSUE;
            elsif vertex_slot < 2 then
              vertex_slot <= vertex_slot + 1;
              state <= ID_ISSUE;
            else
              state <= PRESENT_TRIANGLE;
            end if;

          when PRESENT_TRIANGLE =>
            -- Hold the entire payload, including last, until C accepts it.
            if triangle_ready_i = '1' then
              if face_id = FACE_COUNT then
                state <= IDLE;
              else
                face_id <= face_id + 1;
                vertex_slot <= 0;
                axis <= 0;
                state <= ID_ISSUE;
              end if;
            end if;

          when FAULT =>
            -- A latches err_o; restart requires shared pipeline reset.
            null;
        end case;
      end if;
    end if;
  end process;
end architecture rtl;
