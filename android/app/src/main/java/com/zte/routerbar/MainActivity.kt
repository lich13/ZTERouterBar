package com.zte.routerbar

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel
import com.zte.routerbar.ui.RouterViewModel
import com.zte.routerbar.ui.SignalOverviewScreen
import com.zte.routerbar.ui.ZteRouterBarTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val vmFactory = RouterViewModel.factory(applicationContext)
        setContent {
            ZteRouterBarTheme {
                val routerViewModel: RouterViewModel = viewModel(factory = vmFactory)
                SignalOverviewScreen(viewModel = routerViewModel)
            }
        }
    }
}
