import Members from "../src/members"

private

# Two links to one peer: one dialed by the smaller name and one by the larger. Each node sees them in some order, and
# the first one stays unless the second replaces it.
def kept(first: String, second: String) -> String
  return second if Members.replaces?(second, first)

  first
end

def test_both_nodes_keep_the_link_that_the_smaller_name_dialed_whatever_the_order() -> Result[Void]
  try Test.eq(kept("alpha", "beta"), "alpha")
  Test.eq(kept("beta", "alpha"), "alpha")
end

def test_two_links_dialed_by_the_same_side_keep_the_old_one() -> Result[Void]
  try Test.eq(Members.replaces?("alpha", "alpha"), false)
  Test.eq(Members.replaces?("beta", "beta"), false)
end

def test_the_four_combinations_of_dialers() -> Result[Void]
  try Test.eq(Members.replaces?("alpha", "alpha"), false)
  try Test.eq(Members.replaces?("alpha", "beta"), true)
  try Test.eq(Members.replaces?("beta", "alpha"), false)
  Test.eq(Members.replaces?("beta", "beta"), false)
end
