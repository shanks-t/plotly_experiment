# Import packages
from dash import Dash, html, dash_table, dcc
import pandas as pd
import plotly.express as px

# Incorporate data
df = pd.read_csv('./data/merged_drop_na.csv')

# Calculate GDP change

# Grouping by country means subsequent operations will be performed for each country individually
# GDP.apply() means we are taking the value for GDP_Per_Capita and using it for each country as x in our lambda function, 
# which takes the first and last values using integer location, since we are grouping by GDP we can use iloc[0] to grab first value and subtracting
# that from the last value iloc[-1]

gdp_change = df.groupby('country')['GDP_Per_Capita'].apply(lambda x: x.iloc[-1] - x.iloc[0])

# Top 5 countries with greatest positive change
top_positive = gdp_change.nlargest(5).index.tolist()
# Top 5 countries with greatest negative change
top_negative = gdp_change.nsmallest(5).index.tolist()

positive_df = df[df['country'].isin(top_positive)]


# Initialize the app
app = Dash(__name__)

# App layout
app.layout = html.Div([
    dcc.Graph(
        id='line-plot',
        figure={
            'data': [
                {
                    'x': positive_df[positive_df['country'] == country]['year'],
                    'y': positive_df[positive_df['country'] == country]['total_fertility'],
                    'name': country,
                    'mode': 'lines',
                } for country in positive_df['country'].unique()
            ],
            'layout': {
                'title': 'Fertility Rate Over Time for Countries with Greatest Negative Change in GDP'
            }
        }
    )
])

server = app.server

