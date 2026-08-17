require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "macro_breakdown sizes segments by calories contributed, not by grams" do
    # 52g protein = 208 kcal, 28g fat = 252 kcal, 71g carbs = 284 kcal.
    breakdown = macro_breakdown(protein_g: 52, fat_g: 28, carbs_g: 71)
    shares = breakdown.to_h { |macro| [ macro[:label], macro[:share] ] }

    assert_equal({ "Protein" => 28, "Fat" => 34, "Carbs" => 38 }, shares)

    # The counterintuitive bit, and the reason the share is shown on screen: fewer grams
    # of fat is a wider segment than more grams of protein.
    assert_operator shares["Fat"], :>, shares["Protein"]
  end

  test "macro_breakdown carries grams and labels through for the legend" do
    protein = macro_breakdown(protein_g: 52, fat_g: 28, carbs_g: 71).first

    assert_equal "Protein", protein[:label]
    assert_equal "P", protein[:letter]
    assert_equal 52.0, protein[:grams]
    assert_equal "bg-emerald-500", protein[:color]
  end

  test "macro_breakdown handles an empty day without dividing by zero" do
    breakdown = macro_breakdown(protein_g: 0, fat_g: 0, carbs_g: 0)

    assert_equal [ 0, 0, 0 ], breakdown.map { |macro| macro[:share] }
  end

  test "macro_breakdown tolerates nil columns" do
    breakdown = macro_breakdown(protein_g: nil, fat_g: 10, carbs_g: nil)

    assert_equal [ 0, 100, 0 ], breakdown.map { |macro| macro[:share] }
  end
end
